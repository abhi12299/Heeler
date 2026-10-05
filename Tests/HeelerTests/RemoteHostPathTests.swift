import Testing

@testable import Heeler

@Suite("Remote Host paths")
struct RemoteHostPathTests {
    @Test func windowsPathsRequireADriveRootOrCompleteUNCShare() {
        for path in [#"C:\"#, #"C:\Users\dev"#, "C:/Users/dev", #"d:\with space\项目"#,
            #"\\server\share"#, #"\\server\share\project"#]
        {
            #expect(RemoteHostPath.isAbsolute(path))
            #expect(RemoteHostPath.isWindowsAbsolute(path))
            #expect(RemoteShellPath.quotedAbsolute(path) == nil)
        }
        for path in ["", "relative/path", "C:", "C:project", #"\Users\dev"#,
            #"\\server"#, #"\\server\"#, #"\\?\C:\project"#, #"\\.\pipe\herdr"#]
        {
            #expect(!RemoteHostPath.isAbsolute(path))
        }
    }

    @Test func windowsPathsRefuseQuotesAndControlCharacters() {
        for path in [#"C:\with'quote"#, #"C:\with"quote"#, "C:/with\0nul",
            "C:/with\nnewline", "C:/with\ttab", "C:/with\u{7F}del"]
        {
            #expect(!RemoteHostPath.isAbsolute(path))
        }
    }

    @Test func posixPathsKeepTheLoginShellSafetyPolicy() {
        for path in ["/", "/home/dev", "/with space", "/项目"] {
            #expect(RemoteHostPath.isAbsolute(path))
            #expect(!RemoteHostPath.isWindowsAbsolute(path))
        }
        #expect(!RemoteHostPath.isAbsolute("/with'quote"))
        #expect(!RemoteHostPath.isAbsolute(#"/with\backslash"#))
        #expect(!RemoteHostPath.isAbsolute("/with\nnewline"))
    }

    @Test func windowsNavigationPreservesSeparatorsAndStopsAtRoots() {
        #expect(RemoteHostPath.childPath(#"C:\"#, name: "Users") == #"C:\Users"#)
        #expect(RemoteHostPath.childPath(#"C:\Users\dev"#, name: "src") == #"C:\Users\dev\src"#)
        #expect(RemoteHostPath.childPath("C:/Users/dev", name: "src") == "C:/Users/dev/src")
        #expect(RemoteHostPath.parentPath(of: #"C:\Users\dev\"#) == #"C:\Users"#)
        #expect(RemoteHostPath.parentPath(of: #"C:\Users"#) == #"C:\"#)
        #expect(RemoteHostPath.parentPath(of: "C:/Users") == "C:/")
        #expect(RemoteHostPath.parentPath(of: #"C:\"#) == nil)
        #expect(RemoteHostPath.parentPath(of: "C:/") == nil)
        #expect(RemoteHostPath.parentPath(of: #"\\server\share\project"#) == #"\\server\share"#)
        #expect(RemoteHostPath.parentPath(of: #"\\server\share\"#) == nil)
    }

    @Test func folderLabelsUseTheHostsSeparators() {
        #expect(RemoteHostPath.lastComponent(of: #"C:\Users\dev\project\"#) == "project")
        #expect(RemoteHostPath.lastComponent(of: "C:/Users/dev/project") == "project")
        #expect(RemoteHostPath.lastComponent(of: #"C:\"#) == #"C:\"#)
        #expect(RemoteHostPath.lastComponent(of: "/home/dev/project/") == "project")
        #expect(RemoteHostPath.lastComponent(of: "/") == "/")
    }
}
