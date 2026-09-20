import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = {
  title: "Terms of Service — Family Documents",
  description: "Terms governing early-access use of the Family Documents service.",
  alternates: { canonical: "/terms" },
};

export default function TermsOfService() {
  return <main className="legal-page">
    <nav className="legal-nav"><Link className="wordmark" href="/"><span>FD</span>Family Documents</Link><a href="/app/">Sign in</a></nav>
    <article className="legal-document">
      <header><p className="eyebrow">Early-access agreement</p><h1>Terms of Service</h1><p className="legal-updated">Last updated 20 September 2026</p><p>These terms govern your use of Family Documents. By creating an account or using the service, you agree to them. If you do not agree, do not use the service. Questions can be sent to <a href="mailto:contact@familydocuments.app">contact@familydocuments.app</a>.</p></header>
      <section><h2>1. The service</h2><p>Family Documents helps households organise documents, reminders, saved links and rental-property bill records. It may provide optional OCR and AI-assisted suggestions that require human review. The service is an organisational tool; it is not legal, financial, tax, medical, insurance or professional advice.</p></section>
      <section><h2>2. Early access and free trial</h2><p>The service is currently offered free during early access without a credit card. Features may change, be limited or be withdrawn as the product develops. We will provide reasonable notice before introducing charges for continued use; you will not be charged unless you expressly choose a paid plan.</p></section>
      <section><h2>3. Accounts and family workspaces</h2><p>You must provide accurate account information, safeguard your credentials and promptly report suspected misuse. You are responsible for invitations you send, roles you assign and the content and sharing choices in your household workspace. Do not access another person&apos;s account or records without permission.</p></section>
      <section><h2>4. Your content</h2><p>You retain ownership of content you add. You give us a limited permission to host, process, copy and transmit that content only as needed to operate, secure and improve the features you request. You confirm that you have the right to add the content and share it with the people you select.</p><p>Keep your own backup of irreplaceable records. Family Documents should not be the only copy of a passport, policy, title, tax record or other important document.</p></section>
      <section><h2>5. Connected storage and Google Drive</h2><p>Connected storage remains governed by the provider&apos;s terms. In the current release, original documents saved through the app are kept in the family-selected Google Drive folder. The service retains organisational and derived information needed to operate the app. Google Drive access is limited to files and folders the app creates or you explicitly select under the permission shown by Google. You are responsible for maintaining access to your provider account. Disconnecting Family Documents does not delete provider originals.</p></section>
      <section><h2>6. Acceptable use</h2><p>You must not use the service to break the law; harm, threaten or deceive others; upload malware; probe or bypass security; interfere with availability; send spam; infringe rights; or store or share content you are not authorised to handle. We may restrict activity that creates a security, legal or operational risk.</p></section>
      <section><h2>7. Availability and changes</h2><p>We aim to provide a reliable service but do not promise uninterrupted or error-free availability, especially during early access. Maintenance, home-server availability, internet providers and third-party services may affect access. We may modify features to improve safety, reliability or usefulness.</p></section>
      <section><h2>8. Suspension and ending use</h2><p>You may stop using the service at any time and request account deletion. We may suspend or end access for serious or repeated breaches, security threats, legal requirements or discontinuation of the service. Where reasonably possible, we will provide notice and an opportunity to export supported information.</p></section>
      <section><h2>9. Responsibility and liability</h2><p>Nothing in these terms excludes rights or remedies that cannot legally be excluded, including applicable rights under New Zealand consumer law. To the extent permitted by law, Family Documents is provided on an “as available” basis and we are not responsible for indirect or consequential loss, decisions made from unconfirmed suggestions, provider outages, or loss caused by your sharing choices, account compromise or failure to keep independent backups.</p></section>
      <section><h2>10. Privacy</h2><p>Our <a href="/privacy">Privacy Policy</a> explains how we handle personal information and Google user data. It forms part of these terms.</p></section>
      <section><h2>11. Governing law and changes</h2><p>These terms are governed by New Zealand law. We may update them as the service develops. We will give reasonable notice of material changes, and continued use after the effective date means you accept the updated terms.</p></section>
    </article>
    <footer className="legal-footer"><Link href="/">Home</Link><a href="/privacy">Privacy Policy</a><a href="mailto:contact@familydocuments.app">Contact</a></footer>
  </main>;
}
