/**
 * /dashboard/chaos/page.tsx — Chaos Mode Configuration
 */
import { getTranslations } from "next-intl/server";
import ChaosConfigPageClient from "./ChaosConfigPageClient";
import { APP_CONFIG } from "@/shared/constants/appConfig";

export async function generateMetadata() {
  const t = await getTranslations("chaosConfig");
  return { title: `${t("pageTitle")} — ${APP_CONFIG.name}` };
}

export default function Page() {
  return <ChaosConfigPageClient />;
}
