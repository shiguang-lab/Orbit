import ConductorPageClient from "./ConductorPageClient";
import { APP_CONFIG } from "@/shared/constants/appConfig";

export const metadata = {
  title: `Conductor — ${APP_CONFIG.name}`,
  description: "OmniConductor CLI-agent fleet: runners, task queue and councils, live.",
};

export default function ConductorPage() {
  return <ConductorPageClient />;
}
