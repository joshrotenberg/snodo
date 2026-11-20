runtime =
  Snodo.Server.Runtime.new(
    router: %Snodo.Router{},
    protocols: [Snodo.Protocol.V2025_11_25],
    server_info: %{"name" => "legacy-extension-fixture", "version" => "1"},
    extensions: [SnodoTest.TestExtensions.LegacyExtension]
  )

:ok = Snodo.Transport.Stdio.serve(runtime, sessions: "--sessions" in System.argv())
