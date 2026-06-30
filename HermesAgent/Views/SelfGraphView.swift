import SwiftUI
import WebKit

// MARK: - Data models (Mac 側と同構造の iOS コピー)

struct SelfGraphNode: Codable, Identifiable {
    var id: String
    var label: String
    var type: String       // self|goal|interest|project|tech|concept|person|place|memo
    var desc: String
    var size: Int
    var createdAt: Double
}

struct SelfGraphLink: Codable {
    var source: String
    var target: String
    var weight: Int
}

struct SelfGraph: Codable {
    var nodes: [SelfGraphNode]
    var links: [SelfGraphLink]
}

// MARK: - Retain-cycle breaker for WKScriptMessageHandler

private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ ucc: WKUserContentController, didReceive msg: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: msg)
    }
}

// MARK: - ViewModel

@MainActor
final class GraphViewModel: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {

    @Published var selectedNode: SelfGraphNode?
    @Published var isLoading = true

    let webView: WKWebView
    var apiClient: APIClient?

    private var htmlLoaded = false
    private var pendingReload = false

    override init() {
        let cfg = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        cfg.userContentController.add(WeakScriptHandler(self), name: "hermesGraph")
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
    }

    // Called from onAppear — idempotent.
    func configure(apiClient: APIClient) {
        self.apiClient = apiClient
        if !htmlLoaded {
            htmlLoaded = true
            webView.loadHTMLString(Self.graphHTML, baseURL: nil)
        } else if pendingReload {
            pendingReload = false
            Task { await reloadGraph() }
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if apiClient != nil {
            Task { await reloadGraph() }
        } else {
            pendingReload = true
        }
    }

    // MARK: Graph operations

    func reloadGraph() async {
        guard let client = apiClient else { return }
        isLoading = true
        do {
            let data = try await client.rawGet("/api/self-graph")
            guard let json = String(data: data, encoding: .utf8) else { return }
            isLoading = false
            try? await webView.evaluateJavaScript("if(typeof loadGraph==='function')loadGraph(\(json));")
        } catch {
            isLoading = false
        }
    }

    func addNode(_ node: SelfGraphNode, connectedTo targets: [String]) async {
        guard let client = apiClient else { return }
        _ = try? await client.rawSend("POST", "/api/self-graph/nodes",
                                      json: ["id": node.id, "label": node.label,
                                             "type": node.type, "desc": node.desc,
                                             "size": node.size,
                                             "createdAt": node.createdAt])
        for t in targets where !t.isEmpty {
            _ = try? await client.rawSend("POST", "/api/self-graph/links",
                                          json: ["source": node.id, "target": t, "weight": 2])
        }
        await reloadGraph()
    }

    func deleteNode(id: String) async {
        guard let client = apiClient else { return }
        _ = try? await client.rawSend("DELETE", "/api/self-graph/nodes/\(id)", json: nil)
        selectedNode = nil
        await reloadGraph()
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ ucc: WKUserContentController, didReceive msg: WKScriptMessage) {
        guard msg.name == "hermesGraph",
              let body = msg.body as? [String: Any],
              let action = body["action"] as? String else { return }
        switch action {
        case "select":
            selectedNode = SelfGraphNode(
                id:        body["id"]        as? String ?? "",
                label:     body["label"]     as? String ?? "",
                type:      body["type"]      as? String ?? "concept",
                desc:      body["desc"]      as? String ?? "",
                size:      body["size"]      as? Int    ?? 12,
                createdAt: body["createdAt"] as? Double ?? 0
            )
        case "deselect":
            selectedNode = nil
        default: break
        }
    }

    // MARK: - Graph HTML (self-contained canvas + pure-JS force simulation)

    // swiftlint:disable line_length
    static let graphHTML = """
    <!DOCTYPE html><html>
    <head>
    <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
    <style>*{margin:0;padding:0;box-sizing:border-box}body{background:transparent;overflow:hidden}canvas{display:block;touch-action:none}</style>
    </head>
    <body><canvas id="c"></canvas>
    <script>
    (function(){
    const cv=document.getElementById('c'),ctx=cv.getContext('2d'),PR=window.devicePixelRatio||1;
    let nodes=[],links=[],raf=null,drag=null,dragPos=null,hl=null;
    const CLR={self:'#7F77DD',goal:'#D85A30',interest:'#EF9F27',project:'#1D9E75',
                tech:'#378ADD',concept:'#888780',person:'#D4537E',place:'#5DCAA5',memo:'#EF9F27'};
    function W(){return cv.width/PR} function H(){return cv.height/PR}
    function resize(){
      cv.style.width=window.innerWidth+'px';cv.style.height=window.innerHeight+'px';
      cv.width=window.innerWidth*PR;cv.height=window.innerHeight*PR;
    }
    window.loadGraph=function(data){
      const cw=W(),ch=H(),nm={};
      nodes=data.nodes.map(n=>{
        const nd={...n,x:cw/2+(Math.random()-.5)*cw*.5,y:ch/2+(Math.random()-.5)*ch*.5,vx:0,vy:0};
        nm[n.id]=nd;return nd;
      });
      links=(data.links||[]).map(l=>({...l,sn:nm[l.source],tn:nm[l.target]})).filter(l=>l.sn&&l.tn);
      hl=null;startSim(280);
    };
    function startSim(n){
      cancelAnimationFrame(raf);let i=0;
      (function tick(){step();draw();i++;
        const mv=nodes.some(n=>Math.abs(n.vx)+Math.abs(n.vy)>.25);
        if(i<n||mv)raf=requestAnimationFrame(tick);
      })();
    }
    function step(){
      const cw=W(),ch=H();
      for(let i=0;i<nodes.length;i++){
        const a=nodes[i];
        a.vx+=(cw/2-a.x)*.0018;a.vy+=(ch/2-a.y)*.0018;
        for(let j=i+1;j<nodes.length;j++){
          const b=nodes[j],dx=b.x-a.x,dy=b.y-a.y,d2=dx*dx+dy*dy+.01;
          const inv=1/Math.sqrt(d2),f=-5800/d2,fx=f*dx*inv,fy=f*dy*inv;
          a.vx+=fx;a.vy+=fy;b.vx-=fx;b.vy-=fy;
        }
      }
      for(const l of links){
        const dx=l.tn.x-l.sn.x,dy=l.tn.y-l.sn.y,d=Math.sqrt(dx*dx+dy*dy)+.01;
        const tgt=115-(l.weight||1)*14,f=(d-tgt)*.038*(l.weight||1),inv=f/d;
        l.sn.vx+=dx*inv;l.sn.vy+=dy*inv;l.tn.vx-=dx*inv;l.tn.vy-=dy*inv;
      }
      for(const n of nodes){
        if(n===drag)continue;
        n.vx*=.82;n.vy*=.82;n.x+=n.vx;n.y+=n.vy;
      }
    }
    function draw(){
      ctx.clearRect(0,0,cv.width,cv.height);
      ctx.save();ctx.scale(PR,PR);
      for(const l of links){
        const conn=!hl||(l.sn===hl||l.tn===hl);
        ctx.globalAlpha=conn?(.15+(l.weight||1)*.08):.035;
        ctx.beginPath();ctx.moveTo(l.sn.x,l.sn.y);ctx.lineTo(l.tn.x,l.tn.y);
        ctx.strokeStyle='#888780';ctx.lineWidth=(l.weight||1)*.65;ctx.stroke();
      }
      ctx.globalAlpha=1;
      for(const n of nodes){
        const r=n.size||12,col=CLR[n.type]||'#888';
        const vis=!hl||n===hl||links.some(l=>(l.sn===hl&&l.tn===n)||(l.tn===hl&&l.sn===n));
        ctx.globalAlpha=vis?1:.15;
        if(n===hl){ctx.beginPath();ctx.arc(n.x,n.y,r*1.6,0,Math.PI*2);ctx.fillStyle=col+'1a';ctx.fill();}
        ctx.beginPath();ctx.arc(n.x,n.y,r,0,Math.PI*2);
        ctx.fillStyle=col+'28';ctx.fill();
        ctx.strokeStyle=col;ctx.lineWidth=n===hl?2.6:1.8;ctx.stroke();
        const fs=Math.max(9,Math.min(r*.56,12.5));
        ctx.font='500 '+fs+'px -apple-system,sans-serif';
        ctx.fillStyle='#fff';ctx.textAlign='center';ctx.textBaseline='middle';
        ctx.shadowColor=col;ctx.shadowBlur=n===hl?7:3;
        ctx.fillText(n.label,n.x,n.y);ctx.shadowBlur=0;
      }
      ctx.globalAlpha=1;ctx.restore();
    }
    function hit(cx,cy){for(const n of nodes){const r=(n.size||12)+5,dx=n.x-cx,dy=n.y-cy;if(dx*dx+dy*dy<r*r)return n;}return null;}
    function msg(obj){try{window.webkit.messageHandlers.hermesGraph.postMessage(obj);}catch(e){}}
    cv.addEventListener('touchstart',e=>{
      e.preventDefault();if(e.touches.length!==1)return;
      const t=e.touches[0],nd=hit(t.clientX,t.clientY);
      if(nd){drag=nd;dragPos={x:t.clientX,y:t.clientY};hl=nd;draw();
        msg({action:'select',id:nd.id,label:nd.label,type:nd.type,desc:nd.desc,size:nd.size,createdAt:nd.createdAt});
      }else{drag=null;hl=null;draw();msg({action:'deselect'});}
    },{passive:false});
    cv.addEventListener('touchmove',e=>{
      e.preventDefault();if(!drag||e.touches.length!==1)return;
      const t=e.touches[0];
      drag.x+=t.clientX-dragPos.x;drag.y+=t.clientY-dragPos.y;
      drag.vx=0;drag.vy=0;dragPos={x:t.clientX,y:t.clientY};draw();
    },{passive:false});
    cv.addEventListener('touchend',e=>{e.preventDefault();drag=null;dragPos=null;},{passive:false});
    window.addEventListener('resize',()=>{resize();if(nodes.length)startSim(60);});
    resize();
    })();
    </script>
    </body></html>
    """
    // swiftlint:enable line_length
}

// MARK: - UIViewRepresentable

struct GraphWebView: UIViewRepresentable {
    let vm: GraphViewModel
    func makeUIView(context: Context) -> WKWebView { vm.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Add Node Sheet

struct AddNodeSheet: View {
    let onSave: (SelfGraphNode, [String]) async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var descText = ""
    @State private var type = "concept"
    @State private var linkedTo = ""

    private let options: [(String, String)] = [
        ("goal", "目標"), ("interest", "好み"), ("project", "プロジェクト"),
        ("tech", "技術"), ("concept", "概念"), ("person", "人"),
        ("place", "場所"), ("memo", "メモ"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("ノード") {
                    TextField("ラベル（例: 読書）", text: $label)
                    TextField("説明", text: $descText)
                }
                Section("種類") {
                    Picker("種類", selection: $type) {
                        ForEach(options, id: \.0) { id, name in Text(name).tag(id) }
                    }.pickerStyle(.menu)
                }
                Section {
                    TextField("接続先ID（カンマ区切り、例: health,growth）", text: $linkedTo)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("つながり（任意）")
                } footer: {
                    Text("既存ノードのID。ホーム画面でノードをタップすると確認できます。")
                }
            }
            .navigationTitle("ノードを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("追加") {
                        let rawId = label.lowercased()
                            .replacingOccurrences(of: " ", with: "-")
                        let id = rawId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0.isMultibyte }
                        let node = SelfGraphNode(
                            id: id.isEmpty ? UUID().uuidString : id,
                            label: label.trimmingCharacters(in: .whitespaces),
                            type: type,
                            desc: descText.trimmingCharacters(in: .whitespaces),
                            size: 13,
                            createdAt: Date().timeIntervalSince1970
                        )
                        let targets = linkedTo.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                        dismiss()
                        Task { await onSave(node, targets) }
                    }
                    .fontWeight(.semibold)
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Selected Node Info Overlay

struct NodeInfoCard: View {
    let node: SelfGraphNode
    let onDelete: () -> Void

    private var typeLabel: String {
        switch node.type {
        case "self": return "自分"
        case "goal": return "目標"
        case "interest": return "好み"
        case "project": return "プロジェクト"
        case "tech": return "技術"
        case "concept": return "概念"
        case "person": return "人"
        case "place": return "場所"
        case "memo": return "メモ"
        default: return node.type
        }
    }

    private var typeColor: Color {
        switch node.type {
        case "self": return .purple
        case "goal": return .orange
        case "interest": return .yellow
        case "project": return .green
        case "tech": return .blue
        case "person": return .pink
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(node.label)
                        .font(.system(.subheadline, weight: .semibold))
                    Text(typeLabel)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(typeColor.opacity(0.15))
                        .foregroundStyle(typeColor)
                        .clipShape(Capsule())
                }
                if !node.desc.isEmpty {
                    Text(node.desc)
                        .font(.system(size: 13, weight: .light))
                        .foregroundStyle(.secondary)
                }
                Text("ID: \(node.id)")
                    .font(.system(size: 11, weight: .light))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            Spacer()
            if node.type != "self" {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 15))
                        .foregroundStyle(.red.opacity(0.75))
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.08), radius: 8, y: -2)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Main View

struct SelfGraphView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = GraphViewModel()
    @State private var showingAddNode = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Graph canvas
            GraphWebView(vm: vm)
                .ignoresSafeArea()

            // Loading spinner
            if vm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground).opacity(0.5))
            }

            // Selected node info
            if let node = vm.selectedNode {
                NodeInfoCard(node: node) {
                    Task { await vm.deleteNode(id: node.id) }
                }
            }
        }
        .animation(.spring(duration: 0.26), value: vm.selectedNode?.id)
        .navigationTitle("頭の中")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAddNode = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddNode) {
            AddNodeSheet { node, targets in
                await vm.addNode(node, connectedTo: targets)
            }
        }
        .onAppear {
            vm.configure(apiClient: appState.apiClient)
        }
    }
}

// MARK: - Character helper

private extension Character {
    var isMultibyte: Bool { utf16.count > 1 }
}
