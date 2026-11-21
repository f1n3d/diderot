import Foundation

extension Endpoints {
    /// Workspace announcements (license feature `announcements`, Docmost 0.98). 404 where the server has no enterprise
    /// code.
    public enum Announcements {
        public static var visible: Endpoint<VisibleAnnouncements> { .post("announcements/visible") }
    }
}
