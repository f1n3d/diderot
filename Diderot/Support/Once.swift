/// A value made the first time it's asked for, then kept. As a `@State` default it's cheap to build again on every init
/// of its view, which SwiftUI runs on each pass of the parent and keeps only the first of, unlike the value itself (a
/// web page and its data store).
final class Once<Value> {
    private var value: Value?

    func callAsFunction(_ make: () -> Value) -> Value {
        if let value { return value }
        let made = make()
        value = made
        return made
    }
}
