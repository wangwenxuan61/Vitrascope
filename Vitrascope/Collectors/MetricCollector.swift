protocol MetricCollector {
    associatedtype Reading
    mutating func collect() -> Reading
}
