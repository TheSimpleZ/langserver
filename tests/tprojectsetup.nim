import
  std/[options, json, os, jsonutils, sequtils, strutils, sugar, strformat],
  json_rpc/[rpcclient],
  chronicles,
  unittest2,
  ../[nimlangserver, ls, lstransports, utils],
  ../protocol/[enums, types],
  ./[lspsocketclient, testhelpers]

suite "nimble setup":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams) #we could accesss to the ls here to test against its state
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "extension/statusUpdate",
    "textDocument/publishDiagnostics", "$/progress",
  )
  let testProjectDir = absolutePath "tests" / "projects" / "testproject"

  test "should pick `testproject.nim` as the main file and provide suggestions":
    let entryPoint = testProjectDir / "src" / "testproject.nim"
    createNimbleProject(testProjectDir)
    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects/testproject"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    discard waitFor client.initialize(initParams)

    check waitFor client.waitForNotificationMessage(
      fmt"Nimsuggest initialized for {entryPoint}"
    )

    let completionParams =
      CompletionParams %* {
        "position": {"line": 7, "character": 0},
        "textDocument": {"uri": pathToUri(entryPoint)},
      }
    let ns = waitFor ls.projectFiles[entryPoint].ns
    client.notify(
      "textDocument/didOpen",
      %createDidOpenParams("projects/testproject/src/testproject.nim"),
    )
    check waitFor client.waitForNotification(
      "window/showMessage",
      (json: JsonNode) =>
        json["message"].to(string) == &"Opening {pathToUri(entryPoint)}",
    )

    #We need to make two calls (ns issue)
    discard client.call("textDocument/completion", %completionParams).waitFor
    let completionList = client
      .call("textDocument/completion", %completionParams).waitFor
      .to(seq[CompletionItem])
      .mapIt(it.label)
    check completionList.len > 0

  test "`submodule.nim` should not be part of the nimble project file":
    let submodule = testProjectDir / "src" / "testproject" / "submodule.nim"
    client.notify(
      "textDocument/didOpen",
      %createDidOpenParams("projects/testproject/src/testproject/submodule.nim"),
    )

    check waitFor client.waitForNotification(
      "window/showMessage",
      (json: JsonNode) => json["message"].to(string) == &"Opening {pathToUri(submodule)}",
    )

    check ls.projectFiles.len == 1

  test "getNimbleDumpInfo reports the project's name and srcDir and caches it":
    let nimbleFile = testProjectDir / "testproject.nimble"
    let info = waitFor ls.getNimbleDumpInfo(nimbleFile)
    check info.name == "testproject"
    check info.srcDir == "src"
    check nimbleFile in ls.nimDumpCache

    let cached = waitFor ls.getNimbleDumpInfo(nimbleFile)
    check cached.name == info.name
    check cached.srcDir == info.srcDir

suite "Project Mapping":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams) #we could accesss to the ls here to test against its state
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "extension/statusUpdate",
    "textDocument/publishDiagnostics", "$/progress",
  )
  let projectsDir = absolutePath "tests" / "projects"

  test "should use projectMapping fileRegex to find project file":
    let initParams =
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects"),
        "capabilities":
          {"window": {"workDoneProgress": true}, "workspace": {"configuration": true}},
      }
    discard waitFor client.initialize(initParams)
    let configurationParams =
      @[NlsConfig(projectMapping: some @[NlsNimsuggestConfig(fileRegex: "nonimble*")])]
    let nonimbleProject = projectsDir / "nonimbleproject.nim"
    ls.setWorkspaceConfiguration(%configurationParams)

    let projectFile = waitFor getProjectFile(nonimbleProject, ls)
    let matchingMsg = fmt"RegEx matched `nonimble*` for file `{nonimbleProject}`"

    check waitFor client.waitForNotification(
      "window/showMessage",
      proc(json: JsonNode): bool =
        json["message"].getStr == matchingMsg,
    )
    let expectedProjectFile = nonimbleProject

    check projectFile == expectedProjectFile

suite "Resolving against the nimsuggests already running":
  let cmdParams =
    CommandLineParams(mode: some lsp, transport: some socket, port: getNextFreePort())
  let ls = main(cmdParams)
  let client = newLspSocketClient()
  waitFor client.connect("localhost", cmdParams.port)
  client.registerNotification(
    "window/showMessage", "window/workDoneProgress/create", "workspace/configuration",
    "extension/statusUpdate", "textDocument/publishDiagnostics", "$/progress",
  )
  let projectsDir = absolutePath "tests" / "projects"

  suiteTeardown:
    waitFor ls.stopNimsuggestProcesses()

  test "a file a running project knows goes to that project, not a new one":
    # `slowroot/other.nim` is imported by `slowroot/mappedroot.nim` and by
    # nothing else. The guess cannot know that: it looks for a module named
    # after a parent directory, finds `slowroot/slowroot.nim`, and hands the
    # file to a project that never compiled it.
    discard waitFor client.initialize(
      LspInitializeParams %* {
        "processId": %getCurrentProcessId(),
        "rootUri": fixtureUri("projects"),
        "capabilities":
          {"window": {"workDoneProgress": false}, "workspace": {"configuration": true}},
      }
    )
    # Unlimited processes, so the fallback that reuses the first project
    # cannot be what makes this pass.
    ls.setWorkspaceConfiguration(
      %(@[NlsConfig(maxNimsuggestProcesses: some 0, autoCheckFile: some false)])
    )

    let
      mappedRoot = projectsDir / "slowroot" / "mappedroot.nim"
      other = projectsDir / "slowroot" / "other.nim"
      slowRoot = projectsDir / "slowroot" / "slowroot.nim"

    waitFor ls.createOrRestartNimsuggest(mappedRoot).wait(60.seconds)
    check waitUntil(mappedRoot in ls.projectFiles, timeout = 60.seconds)
    discard waitFor ls.projectFiles[mappedRoot].ns.wait(60.seconds)

    let projectFile = waitFor getProjectFile(other, ls).wait(60.seconds)
    check projectFile == mappedRoot
    check projectFile != slowRoot
    check projectFile != other
