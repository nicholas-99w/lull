import Darwin

public enum Hardening {
    /// `ptrace(PT_DENY_ATTACH)`: refuses debugger attachment for the life of the
    /// process. Called at launch in Release builds of the agent and
    /// daemon. Raises the bar for a local admin; it is not a security boundary
    /// against root (see SECURITY.md).
    ///
    /// `ptrace` is not exported to Swift, so it's looked up with dlsym.
    public static func denyDebuggerAttach() {
        typealias PtraceFunction = @convention(c) (CInt, pid_t, UnsafeMutablePointer<CChar>?, CInt) -> CInt
        let ptDenyAttach: CInt = 31  // <sys/ptrace.h>
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        guard let sym = dlsym(rtldDefault, "ptrace") else { return }
        _ = unsafeBitCast(sym, to: PtraceFunction.self)(ptDenyAttach, 0, nil, 0)
    }
}
