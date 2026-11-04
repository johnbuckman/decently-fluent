import SwiftUI
import UIKit

/// A place in the book: a chapter and a page of it.
struct PagePlace: Hashable, Comparable {
    var chapter: Int
    var page: Int
    static func < (a: PagePlace, b: PagePlace) -> Bool { (a.chapter, a.page) < (b.chapter, b.page) }
}

/// Pages that turn with a curl, as in Apple Books: drag a page's edge to turn it, or change `place` and it curls
/// forward or back to it. Built on UIPageViewController; each page is a SwiftUI view.
struct PageCurl<Page: View>: UIViewControllerRepresentable {
    /// The page shown.
    let place: PagePlace
    /// Counts each turn made from outside (buttons, taps, keys): a new value curls to `place`; any other change of
    /// `place` (new text size, rotation, a chapter chosen from the menu) just shows it.
    let turns: Int
    /// The page before and after a place, or nil at the start or end of the book.
    let neighbour: (PagePlace, Int) -> PagePlace?
    let style: UIUserInterfaceStyle
    /// The reader curled to a page.
    let onTurn: (PagePlace) -> Void
    @ViewBuilder let page: (PagePlace) -> Page

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
                                       options: [.spineLocation: UIPageViewController.SpineLocation.min.rawValue])
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.isDoubleSided = false
        pvc.view.backgroundColor = .clear
        // the pages' own taps turn them (or pick a word); only the curling drag is the page controller's
        for g in pvc.gestureRecognizers where g is UITapGestureRecognizer { g.isEnabled = false }
        context.coordinator.shown = place
        context.coordinator.turnsSeen = turns
        pvc.setViewControllers([context.coordinator.host(place)], direction: .forward, animated: false)
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        let c = context.coordinator
        c.parent = self
        if place != c.shown {
            let animated = turns != c.turnsSeen
            let forward = place > c.shown
            c.shown = place
            c.turnsSeen = turns
            if animated {
                // A turn from a tap, button or key: the page lifts from its corner and curls away, revealing the next
                // page underneath (or the page before curls back down over it). The page controller's own animated
                // turn is a straight fold that sweeps across too fast to look like paper.
                let curl = CATransition()
                curl.type = CATransitionType(rawValue: forward ? "pageCurl" : "pageUnCurl")
                curl.subtype = .fromRight
                curl.duration = 0.6
                curl.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                pvc.view.layer.add(curl, forKey: "curl")
            }
            pvc.setViewControllers([c.host(place)], direction: forward ? .forward : .reverse, animated: false)
        } else {
            c.turnsSeen = turns
            // same page, new content (a word tapped, a level changed, text arrived)
            if let host = pvc.viewControllers?.first as? Coordinator.Host {
                host.rootView = AnyView(page(place))
                host.overrideUserInterfaceStyle = style
            }
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageCurl
        var shown = PagePlace(chapter: 0, page: 0)
        var turnsSeen = 0

        init(_ parent: PageCurl) { self.parent = parent }

        final class Host: UIHostingController<AnyView> {
            var place = PagePlace(chapter: 0, page: 0)
        }

        func host(_ place: PagePlace) -> Host {
            let h = Host(rootView: AnyView(parent.page(place)))
            h.place = place
            // a curling page needs to be opaque, like paper
            h.view.backgroundColor = .systemBackground
            h.overrideUserInterfaceStyle = parent.style
            return h
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let h = vc as? Host, let p = parent.neighbour(h.place, -1) else { return nil }
            return host(p)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let h = vc as? Host, let p = parent.neighbour(h.place, 1) else { return nil }
            return host(p)
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let h = pvc.viewControllers?.first as? Host else { return }
            shown = h.place
            parent.onTurn(h.place)
        }
    }
}
