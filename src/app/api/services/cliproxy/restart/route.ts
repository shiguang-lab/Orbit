import { getServiceRow } from "@/lib/db/versionManager";
import { getOrInitSupervisor } from "../_lib";
import { createErrorResponse } from "@/lib/api/errorResponse";
import { sanitizeErrorMessage } from "@omniroute/open-sse/utils/error";
import { resolvePortPid } from "@/lib/services/portProbe";

const TOOL = "cliproxy";

async function waitForProcessExit(pid: number, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      process.kill(pid, 0);
    } catch {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
}

export async function POST(): Promise<Response> {
  try {
    const row = await getServiceRow(TOOL);
    if (!row || row.status === "not_installed") {
      return createErrorResponse({ status: 409, message: "CLIProxyAPI não está instalado." });
    }

    const sup = await getOrInitSupervisor();
    let status = await sup.restart();
    // A separately-loaded route bundle can return an adopted status before it
    // has a tracked PID. Force a final port-owner lookup so restart never
    // leaves the old CLIProxyAPI process running outside Orbit's lifecycle.
    if (status.adopted && status.pid === null) {
      const pid = await resolvePortPid(row.port);
      if (pid !== null) {
        try {
          process.kill(pid, "SIGTERM");
        } catch {
          // The process may have exited between lookup and signal delivery.
        }
        await waitForProcessExit(pid, 15_000);
      }
      await sup.stop();
      status = await sup.start();
    }
    return Response.json(status);
  } catch (err) {
    const msg = sanitizeErrorMessage(err instanceof Error ? err.message : String(err));
    return createErrorResponse({ status: 503, message: msg });
  }
}
