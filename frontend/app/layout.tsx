import type { Metadata } from "next";
import "./globals.css";
import "./legal.css";

export const metadata: Metadata = {
  metadataBase: new URL("https://familydocuments.app"),
  title: "Family Documents — Organise Documents, Reminders & Family Links",
  description: "Keep important family documents, renewal reminders and private saved links organised in one secure workspace. Start free during early access.",
  keywords: ["family document organiser", "document reminder app", "family records", "private bookmark manager", "household documents"],
  alternates: { canonical: "/" },
  openGraph: { title: "Family Documents — Your family, clearly organised", description: "A private home for important documents, reminders and useful family links.", url: "/", siteName: "Family Documents", locale: "en_NZ", type: "website", images: [{url:"/og.png",width:1200,height:630,alt:"Family Documents — Your family, clearly organised."}] },
  twitter: { card: "summary_large_image", title: "Family Documents — Your family, clearly organised", description: "A private home for important documents, reminders and useful family links.", images:["/og.png"] },
  robots: { index: true, follow: true },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en-NZ">
      <body>{children}</body>
    </html>
  );
}
