import type { Metadata } from "next";
import ComboPlaygroundClient from "./ComboPlaygroundClient";
import { APP_CONFIG } from "@/shared/constants/appConfig";

export const metadata: Metadata = {
  title: `${APP_CONFIG.name} — Combo Playground`,
  description: "Simulate combo routing paths visually",
};

export default function ComboPlaygroundPage() {
  return <ComboPlaygroundClient />;
}
