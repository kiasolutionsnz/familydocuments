import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Family Documents — Interactive prototype",
  description: "A private, synthetic-data preview of the Family Documents experience.",
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
