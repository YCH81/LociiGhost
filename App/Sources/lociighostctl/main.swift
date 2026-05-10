import Foundation
import LociiGhostCore

@main
struct LociiGhostCtl {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            printUsage()
            exit(2)
        }

        var socket = LociiGhostPaths.socketPath
        var positional: [String] = []
        var i = 1
        while i < args.count {
            let a = args[i]
            switch a {
            case "--socket":
                if i + 1 < args.count { socket = args[i + 1]; i += 2 } else { i += 1 }
            case "-h", "--help":
                printUsage(); exit(0)
            default:
                positional.append(a); i += 1
            }
        }

        guard let cmd = positional.first else {
            printUsage()
            exit(2)
        }

        let client = DaemonClient(socketPath: socket)
        do {
            try await client.connect()
        } catch {
            FileHandle.standardError.write(Data("connect failed: \(error)\n".utf8))
            exit(1)
        }

        switch cmd {
        case "ping":
            await runCall(client: client, method: "ping")
        case "info":
            await runCall(client: client, method: "daemon.info")
        case "shutdown":
            await runCall(client: client, method: "daemon.shutdown")
        case "call":
            guard positional.count >= 2 else {
                FileHandle.standardError.write(Data("call requires <method>\n".utf8))
                exit(2)
            }
            await runCall(client: client, method: positional[1])
        default:
            FileHandle.standardError.write(Data("unknown command: \(cmd)\n".utf8))
            exit(2)
        }

        await client.disconnect()
    }

    static func runCall(client: DaemonClient, method: String) async {
        do {
            let raw = try await client.callRaw(method)
            let data = try JSONEncoder().encode(raw)
            print(String(data: data, encoding: .utf8) ?? "")
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func printUsage() {
        let usage = """
        usage: lociighostctl [--socket PATH] <command>
          commands:
            ping              -- daemon liveness check
            info              -- daemon.info
            shutdown          -- request daemon to exit
            call <method>     -- send a one-shot RPC call (no params)
        """
        print(usage)
    }
}
