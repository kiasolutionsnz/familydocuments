import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = {
  title: "Delete your account — Family Documents",
  description: "How to request deletion of your FamilyDocuments account and app-held personal data.",
  alternates: { canonical: "/account-deletion" },
};

export default function AccountDeletion() {
  return <main className="legal-page">
    <nav className="legal-nav"><Link className="wordmark" href="/"><span>FD</span>Family Documents</Link><a href="/app/">Sign in</a></nav>
    <article className="legal-document">
      <header><p className="eyebrow">Your account, your choice</p><h1>Delete your FamilyDocuments account</h1><p className="legal-updated">Last updated 20 September 2026</p><p>You can request deletion from the FamilyDocuments app or contact <a href="mailto:contact@familydocuments.app">contact@familydocuments.app</a>.</p></header>
      <section><h2>Delete your account in the app</h2><ol><li>Sign in to FamilyDocuments.</li><li>Open <strong>Profile</strong>.</li><li>Under <strong>Account and data</strong>, choose <strong>Delete account</strong>.</li><li>Review the consequences and type <strong>DELETE</strong> to confirm.</li></ol></section>
      <section><h2>What we delete</h2><p>After identity and family-ownership checks, we remove your FamilyDocuments login, profile, private account data, active membership and connected access credentials. Information that must be retained temporarily for security, fraud prevention, dispute resolution or legal compliance is isolated and removed when that retention period ends.</p></section>
      <section><h2>What happens to family information</h2><p>Shared family records remain available to authorised remaining family members. If you are the Family owner and other members remain, ownership must be transferred before deletion can finish. Private app items belonging only to you are removed through the deletion process.</p></section>
      <section><h2>Your Google Drive is not deleted</h2><p><strong>Deleting your FamilyDocuments account does not delete any files or folders from Google Drive.</strong> We revoke or remove the app&apos;s stored access credential where appropriate, but your Drive content remains under the control of its Google account owner. You can delete Drive content separately in Google Drive if you choose.</p></section>
      <section><h2>Need help?</h2><p>Email <a href="mailto:contact@familydocuments.app">contact@familydocuments.app</a> from the address used for your account. Never send your password, verification code, access token or Google credentials.</p></section>
    </article>
    <footer className="legal-footer"><Link href="/">Home</Link><a href="/privacy">Privacy Policy</a><a href="/terms">Terms of Service</a></footer>
  </main>;
}
