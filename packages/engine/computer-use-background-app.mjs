import { requestComputerUseHelper } from "./computer-use-helper-client.mjs";

export async function requestBackgroundAppLaunch(
  commandDirectory,
  app,
  { timeoutMs = 40_000, pollMs = 25 } = {},
) {
  try {
    const response = await requestComputerUseHelper(
      commandDirectory,
      "launchApplication",
      { appLaunch: app },
      { timeoutMs, pollMs },
    );
    if (response.error) return { success: false, error: response.error };
    if (response.success !== true) {
      return { success: false, error: "The installed application could not be opened." };
    }
    return {
      success: true,
      detail:
        typeof response.stdout === "string" && response.stdout.trim()
          ? response.stdout.trim()
          : "Opened the installed application without activating it.",
    };
  } catch (error) {
    return { success: false, error: error?.message ?? String(error) };
  }
}
