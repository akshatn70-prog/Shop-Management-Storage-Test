import type { CapacitorConfig } from "@capacitor/cli";

const config: CapacitorConfig = {
  appId: "com.akshat.shopmanagement",
  appName: "Shop Management",
  webDir: "dist",
  server: {
    androidScheme: "https"
  }
};

export default config;
