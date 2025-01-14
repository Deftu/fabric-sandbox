import Sandbox
import WinSDK
import WindowsUtils

/// A list of jvm properties that set where the native binaries are loaded from.

private let nativePathProperties = [
  "java.library.path",
  "jna.tmpdir",
  "org.lwjgl.system.SharedLibraryExtractPath",
  "io.netty.native.workdir",
]

private let propsToRewrite =
  nativePathProperties + [
    //"log4j.configurationFile"
  ]

class SandboxCommandLine {
  let args: [String]

  init(_ args: [String]) {
    self.args = args
  }

  func getApplicationPath() throws -> File? {
    let first = args.first
    guard let first = first else {
      return nil
    }
    return File(first)
  }

  // Remove the last 2 slashes from the app path
  func getJavaHome() throws -> File? {
    return try getApplicationPath()?.parent()?.parent()
  }

  func getJvmProp(_ propName: String) -> String? {
    let prop = "-D\(propName)="
    for arg in args {
      if arg.starts(with: prop) {
        return String(arg.dropFirst(prop.count))
      }
    }
    return nil
  }

  // Returns the arguments to pass to the sandboxed JVM.
  func getSandboxArgs(dotMinecraftDir: File, sandboxRoot: File, namedPipe: NamedPipeServer) throws
    -> [String]
  {
    var args = self.args
    var jvmArgsIndex = getJvmProp("java.io.tmpdir") == nil ? -1 : 1
    var foundVersionType = false

    print("Sandboxing arguments: \(args)")

    for i in 0..<args.count {
      if args[i] == "net.fabricmc.sandbox.Main" {
        // Replace the main class with the runtime entrypoint
        args[i] = "net.fabricmc.sandbox.runtime.Main"
      } else if args[i] == "-classpath" || args[i] == "-cp" {
        // Rewrite the classpath to ensure that all of the entries are within the sandbox.
        args[i + 1] = try rewriteClasspath(
          args[i + 1], dotMinecraftDir: dotMinecraftDir, sandboxRoot: sandboxRoot)
      } else if args[i].starts(with: "-D") && jvmArgsIndex < 0 {
        // Find the first JVM argument, so we can insert our own at the same point.
        jvmArgsIndex = i
      } else if args[i] == "--versionType" {
        // Prefix the version type with "Sandbox", so it is clear that the game is running in a sandbox.
        foundVersionType = true
        if args[i + 1] != "release" {
          args[i + 1] = "\(args[i + 1])/Sandbox"
        } else {
          args[i + 1] = "Sandbox"
        }
      } else if args[i] == "--gameDir" {
        // Replace the game directory with the sandbox root.
        args[i + 1] = sandboxRoot.path() + "\\"
      } else if args[i] == "--assetsDir" {
        args[i + 1] = sandboxRoot.child("assets").path()
      }

      for prop in propsToRewrite {
        let prefix = "-D\(prop)="
        if args[i].starts(with: prefix) {
          let value = File(String(args[i].dropFirst(prefix.count)))
          guard value.isChild(of: dotMinecraftDir) else {
            continue
          }
          let relativePath = value.relative(to: dotMinecraftDir)
          let newPath = sandboxRoot.child(relativePath)
          args[i] = "-D\(prop)=\(newPath.path())"
        }
      }
    }

    if jvmArgsIndex != -1 {
      if getJvmProp("java.io.tmpdir") == nil {
        args.insert("-Djava.io.tmpdir=\(sandboxRoot.path())\\temp", at: jvmArgsIndex)
      }

      for prop in nativePathProperties {
        if getJvmProp(prop) == nil {
          args.insert("-D\(prop)=\(sandboxRoot.path())\\temp\\bin", at: jvmArgsIndex)
        }
      }

      args.insert("-Dsandbox.namedPipe=\(namedPipe.path)", at: jvmArgsIndex)

      // Enable this to debug the sandboxed process, you will need to exempt the sandbox from the loopback networking like so:
      // CheckNetIsolation.exe LoopbackExempt -is -p=<SID>
      //args.insert("-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=*:5055", at: jvmArgsIndex)
    } else {
      print("Warning: Failed to find any JVM arguments, sandbox may not work correctly")
    }

    if !foundVersionType {
      args.append("--versionType")
      args.append("Sandbox")
    }

    // Remove any javaagent arguments
    args.removeAll { $0.starts(with: "-javaagent") }
    return args
  }

  // Read the classpath from the arguments and copy the files to the sandbox, returning the new classpath.
  func rewriteClasspath(_ classPathArgument: String, dotMinecraftDir: File, sandboxRoot: File)
    throws -> String
  {
    let classPath = classPathArgument.split(separator: ";")
    var newClasspath: [String] = []

    // Used to store entries that are outside of the minecraft install dir
    // Lazily created to avoid creating the directory if it is not needed.
    let classpathDir = sandboxRoot.child(".classpath")
    try classpathDir.delete()

    for path in classPath {
      let source = File(String(path))

      guard source.exists() else {
        print("Warning: Classpath entry does not exist: \(source)")
        continue
      }

      if !source.isChild(of: dotMinecraftDir) {
        try classpathDir.createDirectory()

        // Hack fix for dev envs, where build/classes/java/main and build/resources/main would be handled as the same entry.
        var name = source.name()
        if source.parent()!.name() == "resources" {
          name = "resources"
        }

        // The classpath entry is not in the minecraft install dir, copy it to the sandbox.
        let target = classpathDir.child(name)
        print("Warning: Copying classpath entry to sandbox: \(source.path()) -> \(target.path())")
        try source.copy(to: target)
        newClasspath.append(target.path())
      } else {
        // The classpath entry is located within the minecraft jar, so will be mounted into the sandbox.
        let relativePath = source.relative(to: dotMinecraftDir)
        let sandboxPath = sandboxRoot.child(relativePath)
        newClasspath.append(sandboxPath.path())
      }
    }
    return newClasspath.joined(separator: ";")
  }
}
