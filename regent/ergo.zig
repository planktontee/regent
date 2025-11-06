pub fn asPtrConCast(T: type, value: *const T) *T {
    return @constCast(value);
}
