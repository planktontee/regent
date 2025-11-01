pub fn Result(Ok: type, Err: type) type {
    return union(enum) {
        Ok: Ok,
        Err: Err,
    };
}
