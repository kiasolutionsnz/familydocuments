import type { MetadataRoute } from "next";
export default function sitemap(): MetadataRoute.Sitemap { const lastModified=new Date(); return [
  {url:"https://familydocuments.app",lastModified,changeFrequency:"weekly",priority:1},
  {url:"https://familydocuments.app/privacy",lastModified,changeFrequency:"monthly",priority:.3},
  {url:"https://familydocuments.app/terms",lastModified,changeFrequency:"monthly",priority:.3},
]; }
