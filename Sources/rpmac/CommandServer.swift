import Foundation

/// Unix socket server that accepts commands — this lets you bind keys via skhd or similar
/// to send commands like: echo "split-h" | nc -U /tmp/rpmac.sock
class CommandServer {
    let socketPath: String
    let wm: WindowManager
    private var serverSocket: Int32 = -1

    init(socketPath: String = "/tmp/rpmac.sock", wm: WindowManager) {
        self.socketPath = socketPath
        self.wm = wm
    }

    func start() {
        // Clean up stale socket
        unlink(socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            print("Failed to create socket")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                    _ = strcpy(dest, ptr)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            print("Failed to bind socket: \(String(cString: strerror(errno)))")
            return
        }

        listen(serverSocket, 5)
        print("Listening on \(socketPath)")

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while true {
                let client = accept(serverSocket, nil, nil)
                guard client >= 0 else { continue }

                var buffer = [UInt8](repeating: 0, count: 256)
                let n = read(client, &buffer, buffer.count - 1)
                close(client)

                guard n > 0 else { continue }
                let cmd = String(bytes: buffer[0..<n], encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                DispatchQueue.main.async { [self] in
                    self.handleCommand(cmd)
                }
            }
        }
    }

    func handleCommand(_ cmd: String) {
        print(">> \(cmd)")
        switch cmd {
        case "split-h", "hsplit":
            wm.splitHorizontal()
            wm.printStatus()
        case "split-v", "vsplit":
            wm.splitVertical()
            wm.printStatus()
        case "remove":
            wm.removeFrame()
            wm.printStatus()
        case "only":
            wm.only()
            wm.printStatus()
        case "next":
            wm.nextWindowInFrame()
            wm.printStatus()
        case "prev":
            wm.prevWindowInFrame()
            wm.printStatus()
        case "next-frame":
            wm.focusNext()
            wm.printStatus()
        case "prev-frame":
            wm.focusPrev()
            wm.printStatus()
        case "last":
            wm.focusLast()
            wm.printStatus()
        case "swap":
            wm.swapNext()
            wm.printStatus()
        case "kill":
            wm.killWindow()
            wm.printStatus()
        case "capture", "pull":
            wm.captureWindow()
            wm.printStatus()
        case "release":
            wm.releaseWindow()
            wm.printStatus()
        case "next-unmanaged":
            wm.nextWindowInFrame()
            wm.printStatus()
        case "next-screen":
            wm.focusNextScreen()
            wm.printStatus()
        case "prev-screen":
            wm.focusPrevScreen()
            wm.printStatus()
        case "move-to-screen":
            wm.moveWindowToNextScreen()
            wm.printStatus()
        case "rescreen":
            wm.rescreen()
            wm.printStatus()
        case "undo":
            wm.undo()
            wm.printStatus()
        case "redo":
            wm.redo()
            wm.printStatus()
        case "status", "info":
            wm.printStatus()
        case "quit":
            print("Shutting down.")
            unlink(socketPath)
            exit(0)
        default:
            print("Unknown command: \(cmd)")
        }
    }

    func stop() {
        if serverSocket >= 0 {
            close(serverSocket)
        }
        unlink(socketPath)
    }
}
