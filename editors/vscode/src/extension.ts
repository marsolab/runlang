import * as vscode from "vscode";

/**
 * Run Language Debug Extension
 *
 * Registers a debug adapter that spawns `run debug --dap <file.run>` over stdio.
 * The Run compiler's built-in DAP server handles all debug operations (breakpoints,
 * stepping, variable inspection, evaluate).
 */

export function activate(context: vscode.ExtensionContext) {
  // Register the debug adapter descriptor factory
  const factory = new RunDebugAdapterFactory();
  context.subscriptions.push(
    vscode.debug.registerDebugAdapterDescriptorFactory("run", factory)
  );

  // Register a configuration provider for dynamic launch configs
  const provider = new RunDebugConfigurationProvider();
  context.subscriptions.push(
    vscode.debug.registerDebugConfigurationProvider("run", provider)
  );
}

export function deactivate() {
  // Nothing to clean up
}

/**
 * Provides default debug configuration when none exists.
 */
class RunDebugConfigurationProvider
  implements vscode.DebugConfigurationProvider
{
  resolveDebugConfiguration(
    _folder: vscode.WorkspaceFolder | undefined,
    config: vscode.DebugConfiguration,
    _token?: vscode.CancellationToken
  ): vscode.ProviderResult<vscode.DebugConfiguration> {
    // If no launch.json or empty config, provide defaults
    if (!config.type && !config.request && !config.name) {
      const editor = vscode.window.activeTextEditor;
      if (editor && editor.document.languageId === "run") {
        config.type = "run";
        config.name = "Debug Run Program";
        config.request = "launch";
        config.program = "${file}";
      }
    }

    if (!config.program) {
      return vscode.window
        .showInformationMessage("Cannot find a .run file to debug")
        .then((_) => undefined);
    }

    return config;
  }
}

/**
 * Creates the debug adapter process.
 *
 * Spawns `run debug --dap <program>` as a stdio-based debug adapter.
 * The Run compiler's DAP server communicates using Content-Length framed
 * JSON messages over stdin/stdout, which VS Code understands natively.
 */
class RunDebugAdapterFactory
  implements vscode.DebugAdapterDescriptorFactory
{
  createDebugAdapterDescriptor(
    session: vscode.DebugSession,
    _executable: vscode.DebugAdapterExecutable | undefined
  ): vscode.ProviderResult<vscode.DebugAdapterDescriptor> {
    const program = session.configuration.program;
    const args = ["debug", "--dap"];

    if (program) {
      args.push(program);
    }

    // Spawn the Run compiler's DAP server as a child process
    return new vscode.DebugAdapterExecutable("run", args);
  }
}
