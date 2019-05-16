import Cocoa
import Socket

struct NodeInfo: Decodable {
    var name: String
    var address: String
    var description: String
    enum CodingKeys: String, CodingKey {
        case name = "Host name", address = "Addresses", description = "Description"
    }
    func nodeId() -> String? {
        let parts = description.split(separator: "=")
        if parts.count < 1 { return nil } else { return String(parts[1]) }
    }
}

struct SavedNodeInfo: Decodable {
    var name: String
    var address: String
    var nodeId: String
    enum CodingKeys: String, CodingKey {
        case name = "host_name", address, nodeId = "node_id"
    }
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDelegate, NSTableViewDataSource {

    @IBOutlet weak var window: NSWindow!
    @IBOutlet weak var addHubPanel: NSPanel!
    @IBOutlet weak var statusBarMenu: NSMenu!
    @IBOutlet weak var autoModeButton: NSButton!
    @IBOutlet weak var hubListTable: NSTableView!
    @IBOutlet weak var hubIP: NSTextField!
    @IBOutlet weak var hubPort: NSTextField!

    let statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    let unixSocketPath = "/tmp/gu-provider.socket"
    var serverProcessHandle: Process?
    var localServerRequestTimer: Timer?

    var nodes: [NodeInfo] = []
    var nodeSelected: [Bool] = []

    struct ServerResponse: Decodable {
        let envs: [String:String]
    }

    func isServerReady() -> Bool {
        guard let status = getHTTPBodyFromUnixSocket(path: unixSocketPath, method: "GET", query: "/status?timeout=5", body: "") else { return false }
        do {
            let json = try JSONDecoder().decode(ServerResponse.self, from:status.data(using: .utf8)!)
            let status = json.envs["hostDirect"] ?? "Error"
            return status == "Ready"
        } catch {
            return false
        }

    }

    @objc func updateServerStatus() {
        self.setMenuBarText(text: isServerReady() ? "" : "!");
    }

    func requestHTTPFromUnixSocket(path: String, method: String, query: String, body: String) -> String? {
        do {
            let socket = try Socket.create(family: .unix, type: Socket.SocketType.stream, proto: .unix)
            if (try? socket.connect(to: path)) == nil { socket.close(); return nil }
            var additional_headers = ""
            if body != "" {
                additional_headers += "Content-length: " + String(body.lengthOfBytes(using: .utf8)) + "\r\n"
                additional_headers += "Content-type: application/json\r\n"
            }
            if (try? socket.write(from: method + " " + query + " HTTP/1.0\r\n" + additional_headers + "\r\n")) == nil { socket.close(); return nil }
            var result = ""
            while true {
                let str = try? socket.readString()
                if str == nil || str! == nil { break } else { result += str!! }
            }
            socket.close()
            return result
        } catch {
            return nil
        }
    }

    func getHTTPBodyFromUnixSocket(path: String, method: String, query: String, body: String) -> String? {
        guard let response = requestHTTPFromUnixSocket(path: path, method: method, query: query, body: body) else { return nil }
        let body = response.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        return body
    }

    func getHTTPBodyFromUnixSocketAsData(path: String, method: String, query: String, body: String) -> Data? {
        return getHTTPBodyFromUnixSocket(path: path, method: method, query: query, body: body)?.data(using: .utf8, allowLossyConversion: false)
    }

    func launchServerPolling() {
        localServerRequestTimer = Timer.scheduledTimer(timeInterval: 10, target: self,
                                                       selector: #selector(updateServerStatus), userInfo: nil, repeats: true)
    }

    func setMenuBarText(text: String) {
        DispatchQueue.main.async {
            self.statusBarItem.button!.title = text
        }
    }

    func addStatusBarMenu() {
        statusBarItem.button?.image = NSImage.init(named: "GolemMenuIcon")
        statusBarItem.button?.image?.isTemplate = true
        statusBarItem.button?.imagePosition = NSControl.ImagePosition.imageLeft
        statusBarItem.menu = statusBarMenu
    }

    @IBAction func showConfigurationWindow(_ sender: Any) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(self)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableColumn?.identifier.rawValue != "Selected" {
            let cell = tableView.makeView(withIdentifier:NSUserInterfaceItemIdentifier(tableColumn!.identifier.rawValue + ""), owner: nil) as! NSTableCellView
            let node = nodes[row]
            cell.textField?.stringValue = ["", node.name, node.address, node.address][tableView.tableColumns.firstIndex(of: tableColumn!)!]
            return cell
        } else {
            let cell = tableView.makeView(withIdentifier:NSUserInterfaceItemIdentifier("Selected"), owner: nil) as! NSTableCellView
            (cell.viewWithTag(100) as! NSButton).action = #selector(AppDelegate.checkBoxPressed)
            (cell.viewWithTag(100) as! NSButton).state = nodeSelected[row] ? .on : .off
            return cell
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        return nodes.count
    }

    func getProviderOutput(arguments: [String]) -> Data? {
        let providerProcess = Process()
        providerProcess.launchPath = "/bin/bash"
        providerProcess.arguments = ["-lc", "gu-provider " + arguments.joined(separator: " ")]
        let pipe = Pipe()
        providerProcess.standardOutput = pipe
        providerProcess.standardError = nil
        providerProcess.launch()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        providerProcess.waitUntilExit()
        return data
    }

    func dataToBool(data: Data) -> Bool? { return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespaces).lowercased() == "true" }

    func reloadHubList() {
        guard let auto = getHTTPBodyFromUnixSocketAsData(path: unixSocketPath, method: "GET", query: "/nodes/auto", body: "") else {
            NSLog("Cannot connect or invalid response (/nodes/auto)");
            return
        }
        autoModeButton.state = (dataToBool(data: auto) ?? false) ? .on : .off
        var all: Set<String> = []
        guard let data = getHTTPBodyFromUnixSocketAsData(path: unixSocketPath, method: "GET", query: "/lan/list", body: "") else { return }
        nodes = try! JSONDecoder().decode([NodeInfo].self, from: data)
        nodeSelected = []
        for node in nodes {
            guard let status = getHTTPBodyFromUnixSocketAsData(path: unixSocketPath, method: "GET", query: "/nodes/" + node.nodeId()!, body: "")
                else { return }
            nodeSelected.append(dataToBool(data: status)!)
            all.insert(node.nodeId()!)
        }
        guard let saved_nodes_data = getHTTPBodyFromUnixSocketAsData(path: unixSocketPath, method: "GET", query: "/nodes?saved", body: "")
            else { return }
        let saved_nodes = try! JSONDecoder().decode([SavedNodeInfo].self, from: saved_nodes_data)
        for node in saved_nodes {
            if !all.contains(node.nodeId) {
                nodes.append(NodeInfo(name: node.name, address: node.address, description: "node_id=" + node.nodeId))
                guard let status = getHTTPBodyFromUnixSocketAsData(path: unixSocketPath, method: "GET", query: "/nodes/" + node.nodeId, body: "") else { return }
                nodeSelected.append(dataToBool(data: status)!)
                all.insert(node.nodeId)
            }
        }
        hubListTable.reloadData()
    }

    struct AddressAndHostName : Encodable {
        var address: String
        var hostName: String
    }

    @objc func checkBoxPressed(sender: NSButton) {
        let row = hubListTable.row(for:sender)
        let encodedBody = String(data: try! JSONEncoder().encode(AddressAndHostName(address: nodes[row].address, hostName: nodes[row].name)), encoding: .utf8)!
        let _ = getHTTPBodyFromUnixSocket(path: unixSocketPath,
                                          method: sender.state == .on ? "PUT" : "DELETE",
                                          query: "/nodes/" + nodes[row].nodeId()!,
                                          body: encodedBody)
        let _ = getHTTPBodyFromUnixSocket(path: unixSocketPath, method: "POST", query: "/connections/" + (sender.state == .on ? "connect" : "disconnect") + "?save=1", body: "[" + nodes[row].address + "]")
    }

    @IBAction func addHubPressed(_ sender: NSButton) {
        addHubPanel.makeKeyAndOrderFront(self)
    }

    @IBAction func refreshPressed(_ sender: NSButton) {
        reloadHubList()
    }

    @IBAction func autoConnectPressed(_ sender: NSButton) {
        let _ = getHTTPBodyFromUnixSocket(path: unixSocketPath, method: sender.state == .on ? "PUT" : "DELETE", query: "/nodes/auto", body: "{}")
        let _ = getHTTPBodyFromUnixSocket(path: unixSocketPath, method: "POST", query: "/connections/mode/" + (sender.state == .on ? "auto" : "manual") + "?save=1", body: "")
    }

    func showError(message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @IBAction func addEnteredHub(_ sender: NSButton) {
        let ipPort = hubIP.stringValue + ":" + hubPort.stringValue
        // TODO check IP
        let urlString = "http://" + ipPort + "/node_id/"
        URLSession.shared.dataTask(with: URL(string: urlString)!) { (data, res, err) in
            if data == nil || err != nil { self.showError(message: "Cannot connect to " + ipPort); return }
            let nodeIdAndHostName = String(data: data!, encoding: .utf8)!.split(separator: " ")
            if nodeIdAndHostName.count != 2 || (res as! HTTPURLResponse).statusCode != 200 {
                self.showError(message: "Bad answer from " + urlString + ".")
                return
            }
            let encodedBody = String(data: try! JSONEncoder().encode(AddressAndHostName(address: ipPort, hostName: String(nodeIdAndHostName[1]))), encoding: .utf8)!
            let _ = self.getHTTPBodyFromUnixSocket(path: self.unixSocketPath,
                                              method: "PUT",
                                              query: "/nodes/" + String(nodeIdAndHostName[0]),
                                              body: encodedBody)
            DispatchQueue.main.async {
                self.reloadHubList()
                self.hubIP.stringValue = ""
                self.addHubPanel.orderOut(self)
            }
        }.resume()
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        addHubPanel.isFloatingPanel = true
        addStatusBarMenu()
        launchServerPolling()
        reloadHubList()
        if !UserDefaults.standard.bool(forKey: "firstRun") {
            UserDefaults.standard.set(true, forKey: "firstRun")
            showConfigurationWindow(self)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        localServerRequestTimer?.invalidate()
        serverProcessHandle?.terminate()
    }

    @IBAction func quitApp(_ sender: Any) {
        NSApplication.shared.terminate(self)
    }

}
