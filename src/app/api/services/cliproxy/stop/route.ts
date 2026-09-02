import { getSupervisor } from "@/lib/services/registry";
import { getServiceRow } from "@/lib/db/versionManager";
import { getOrInitSupervisor } from "../_lib";
import { createErrorResponse } from "@/lib/api/errorResponse";
import { sanitizeErrorMessage } from "@omniroute/open-sse/utils/error";

const TOOL = "cliproxy";

export async function POST(): Promise<Response> {
  try {
    const row = await getServiceRow(TOOL);
    const existing = getSupervisor(TOOL);
    if (!existing && (!row || row.status !== "running")) {
      return Response.json({ tool: TOOL, state: "stopped" });
    }
    const sup = existing ?? (await getOrInitSupervisor());
    // A supervisor created in this route has no in-memory state yet. Adopt the
    // already-running listener before stopping it so the stop request reaches
    // the real process instead of only updating the DB row.
    if (!existing && row?.status === "running") await sup.start();
    const status = await sup.stop();
    return Response.json(status);
  } catch (err) {
    const msg = sanitizeErrorMessage(err instanceof Error ? err.message : String(err));
    return createErrorResponse({ status: 500, message: msg });
  }
}
