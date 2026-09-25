export interface ShopDownloadsPlugin {
  saveTextToDownloads(options: { fileName: string; content: string }): Promise<{ uri?: string; path: string }>;
}
export declare const ShopDownloads: ShopDownloadsPlugin;
