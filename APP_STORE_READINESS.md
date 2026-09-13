# App Store Readiness

This is the working checklist for the first free release of Downdraft.

## Completed in the project

- iPhone and iPad are both supported from iOS 18.
- PDFs are declared as a document type and opened in place.
- The app has a 1024 × 1024 App Store icon.
- The widget is embedded in the app and shares its App Group correctly.
- iCloud key-value storage is enabled for cross-device reading state.
- `PrivacyInfo.xcprivacy` declares the app's use of `UserDefaults` with
  Apple's approved `CA92.1` reason. The app has no third-party SDKs.
- `PRIVACY_POLICY.md` is a publishable starting point for the required policy.

## Still needed from Dan

1. Pick a public home for the privacy policy and a support contact. A simple
   public webpage is enough; the policy URL must be entered in App Store
   Connect, and the policy should also be linked from within the app.
2. In App Store Connect, create the `com.dan.Downdraft` app record as a free
   iPhone/iPad app. Confirm the bundle identifier and iCloud capability use
   the same Developer Program team as this project.
3. Choose whether the first release is public or unlisted. Unlisted is likely
   the best fit: it is installed normally from an App Store link but cannot be
   found by searching the store.
4. Provide the product-page material: name, subtitle, description, keywords,
   category, age rating, support URL, privacy-policy URL, and iPhone/iPad
   screenshots.
5. Complete App Privacy in App Store Connect based on the final policy. Recheck
   this before submission, especially the iCloud reading-state description.
6. Archive a Release build in Xcode, upload it through Organizer, complete
   export-compliance questions, and submit it for App Review.

## Suggested first listing

- Name: `Downdraft`
- Subtitle: `A focused PDF reader`
- Primary category: Reference
- Price: Free
- Age rating: 4+

### Draft description

Downdraft is a focused PDF reader for iPhone and iPad. Open PDFs directly from
Files or the share sheet, keep several documents open, and return to exactly
where you were reading.

• Read documents in place — no separate bookshelf
• Search, browse a table of contents, and follow PDF links
• Keep quick page bookmarks with visual previews
• Continue from your last page across your Apple devices with iCloud
• Jump back and forward through your reading history
• Find recent documents from a Home Screen or Lock Screen widget

## Suggested review notes

Downdraft is a local PDF reader. It opens PDF files selected by the person
using the app through the system Files picker or share sheet. No account or
sign-in is required. The app uses iCloud key-value storage only to synchronize
the current page, bookmarks, and reading preferences between the same person's
devices; it does not upload PDF files.

## Screenshots to capture

- iPhone: a clean single-page reading view with controls visible.
- iPhone: search with a result selected and the in-document highlight visible.
- iPhone: bookmark rail and scrubber.
- iPad: portrait reading view and document switcher.
- iPad: landscape two-page reading view.
- iPad: table of contents or PDF Information.

## Before every upload

- Increase `CURRENT_PROJECT_VERSION`.
- Test a Release build on an iPhone and iPad, including opening a PDF from
  Files, sharing a PDF from another app, widget handoff, iCloud sync, and
  rotation.
- Verify the privacy policy, support URL, screenshots, and App Privacy answers
  match the submitted binary.
