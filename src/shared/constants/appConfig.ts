import pkg from "../../../package.json" with { type: "json" };

export const APP_CONFIG = {
  name: "智枢",
  description: "AI Gateway for Multi-Provider LLMs",
  version: pkg.version,
  logoPath: "/branding/zhishu-logo.png",
  faviconPath: "/branding/zhishu-favicon.png",
};

export const THEME_CONFIG = {
  storageKey: "theme",
  defaultTheme: "system",
};
