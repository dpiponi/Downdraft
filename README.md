# Downdraft

Downdraft is a deliberately small PDF reader for iPhone and iPad. It is for
reading documents where they already live in Files, rather than importing them
into a new bookshelf or library.

It is vibe-coded.l and is pretty much the perfect PDF reader that I've always wanted.

The only outstanding issue is how best to
sync the "current position" if there's ever lag
or multiple devices open simultaneously.
I haven't inplemented the best strategy
because I don't know what the best strategy is.

## Why it exists

One of the pleasures of a paper book is being able to put a finger between two
pages, briefly look elsewhere, and return without ceremony. Downdraft treats
bookmarks the same way: they are always close at hand, take one action to use,
and do not require naming or organising a collection first.

Bookmarks and reading positions can be shared through iCloud, so it is easy to
continue on another device. A document can also be detached on one device when
you want to explore independently without moving the shared reading position.

## Files-first, not library-first

Downdraft opens PDFs through the standard Files picker and the iOS share sheet.
It keeps the permission needed to reopen the original file, but it does **not**
copy PDFs into its own document store. The files remain where you keep them—in
iCloud Drive, another Files provider, or on the device—and retain their normal
names, folders, and tags.

## Reader features

- Multiple open documents, with a thumbnail document switcher ordered by recent use.
- Remembers the last page of each document and restores documents lazily.
- A clean full-screen reading mode: tap the page to show or hide controls.
- Pinch zooming, text selection, working PDF links, and a gentle snap near
  fit-to-width zoom.
- Vertical or horizontal continuous reading, selected per document.
- PDF contents/outline navigation and a metadata panel.
- Search with previous/next results, all-match highlighting, and result dots
  below the page scrubber.
- Back and forward navigation through meaningful jumps such as links, contents,
  search results, and completed page-scrubber moves.
- A page scrubber with chapter landmarks, bookmark dots, and search-result dots.

## Bookmarks

- Bookmark cards live on a movable rail at the edge of the reader. Their local
  position is remembered separately in portrait and landscape.
- Tap a card to return to its page.
- Press and hold the `+` card to add the current page; press and hold an
  existing card to preview it; swipe a card to remove it.
- Bookmarks show page thumbnails, are kept in page order, and cannot duplicate
  a page.
- Bookmarks are shared through iCloud along with linked reading positions.

## iCloud reading position

Each PDF has a local link control. When linked, your page changes update the
shared position; incoming changes from another device are offered as a choice
instead of silently displacing your reading. When detached, the device keeps
its own place while continuing to share bookmarks.

Visible controls show a small status line with the last successful iCloud
check and the newest page or bookmark update known for the document. This is
intended as useful evidence of what the reader has actually seen, rather than
a promise about when another device will receive a change.

## Home and Lock Screen

The included WidgetKit extension offers recent-document thumbnails and a
“continue reading” widget, including a progress bar. It opens the selected PDF
back in Downdraft.

## Building

Open `Downdraft.xcodeproj` in Xcode, choose an iPhone or iPad simulator (or a
signed device), and run the `Downdraft` scheme. The project uses Apple’s
standard SwiftUI, PDFKit, Files, WidgetKit, and iCloud key-value-store APIs.
