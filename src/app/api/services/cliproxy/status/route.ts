import { getSupervisor } from "@/lib/services/registry";
import { getServiceRow } from "@/lib/db/versionManager";
import {
  getInstalledVersion,
  getLatestVersion,
  CLIPROXY_DEFAULT_PORT,
} from "@/lib/services/installers/cliproxy";
import { createErrorResponse } from "@/lib/api/errorResponse";
import { sanitizeErrorMessage } from "@omniroute/open-sse/utils/error";
import { resolvePortPid } from "@/lib/services/portProbe";

const TOOL = "cliproxy";

export async function GET(): Promise<Response> {
  try {
    const sup = getSupervisor(TOOL);
    const row = await getServiceRow(TOOL);

    let liveStatus = sup?.getStatus() ?? null;
    // Next.js can load this route in a separate server bundle from the
    // instrumentation bootstrap, so its in-memory registry may be empty even
    // while the embedded process is healthy. Resolve the port holder as a
    // fallback instead of reporting a running service with pid=null.
    if (row?.status === "running" && (!liveStatus || liveStatus.pid === null)) {
      const pid = await resolvePortPid(row.port);
      if (pid !== null) {
        liveStatus = liveStatus
          ? { ...liveStatus, pid }
          : {
              tool: TOOL,
              state: "running",
              pid,
              port: row.port,
              health: "unknown",
              startedAt: null,
              lastError: row.errorMessage,
              adopted: true,
            };
      }
    }
    const installedVersion = await getInstalledVersion();
    const latestVersion = await getLatestVersion();

    return Response.json({
      tool: TOOL,
      state: liveStatus?.state ?? row?.status ?? "unknown",
      pid: liveStatus?.pid ?? null,
      port: liveStatus?.port ?? row?.port ?? CLIPROXY_DEFAULT_PORT,
      health: liveStatus?.health ?? "unknown",
      startedAt: liveStatus?.startedAt ?? null,
      lastError: liveStatus?.lastError ?? row?.errorMessage ?? null,
      installedVersion: installedVersion ?? row?.installedVersion ?? null,
      latestVersion,
      updateAvailable: !!installedVersion && !!latestVersion && installedVersion !== latestVersion,
      autoStart: row?.autoStart ?? false,
      providerExpose: row?.providerExpose ?? false,
      adopted: liveStatus?.adopted ?? false,
      autoRestartAdopted: row?.autoRestartAdopted ?? false,
    });
  } catch (err) {
    const msg = sanitizeErrorMessage(err instanceof Error ? err.message : String(err));
    return createErrorResponse({ status: 500, message: msg });
  }
}
