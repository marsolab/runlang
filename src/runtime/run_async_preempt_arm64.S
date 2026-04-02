.text
.globl run_async_preempt
#if defined(__APPLE__)
.globl _run_async_preempt
_run_async_preempt:
#endif
run_async_preempt:
    /* Save caller-saved registers */
    stp     x0, x1, [sp, #-16]!
    stp     x2, x3, [sp, #-16]!
    stp     x4, x5, [sp, #-16]!
    stp     x6, x7, [sp, #-16]!
    stp     x8, x9, [sp, #-16]!
    stp     x10, x11, [sp, #-16]!
    stp     x12, x13, [sp, #-16]!
    stp     x14, x15, [sp, #-16]!
    stp     x16, x17, [sp, #-16]!
    str     x18, [sp, #-16]!
    /* Call run_yield() */
#if defined(__APPLE__)
    bl      _run_yield
#else
    bl      run_yield
#endif
    /* Restore */
    ldr     x18, [sp], #16
    ldp     x16, x17, [sp], #16
    ldp     x14, x15, [sp], #16
    ldp     x12, x13, [sp], #16
    ldp     x10, x11, [sp], #16
    ldp     x8, x9, [sp], #16
    ldp     x6, x7, [sp], #16
    ldp     x4, x5, [sp], #16
    ldp     x2, x3, [sp], #16
    ldp     x0, x1, [sp], #16
    ret

#if defined(__linux__)
.section .note.GNU-stack,"",@progbits
#endif
