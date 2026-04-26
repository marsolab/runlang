.text
.globl run_async_preempt
#if defined(__APPLE__)
.globl _run_async_preempt
_run_async_preempt:
#endif
run_async_preempt:
    /* Save all general-purpose registers that normal function calls may touch
       or that run_context_switch would otherwise capture from run_yield. */
    str     x30, [sp, #-16]!
    str     x29, [sp, #-16]!
    stp     x27, x28, [sp, #-16]!
    stp     x25, x26, [sp, #-16]!
    stp     x23, x24, [sp, #-16]!
    stp     x21, x22, [sp, #-16]!
    stp     x19, x20, [sp, #-16]!
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
    bl      _run_async_preempt_done
#else
    bl      run_yield
    bl      run_async_preempt_done
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
    ldp     x19, x20, [sp], #16
    ldp     x21, x22, [sp], #16
    ldp     x23, x24, [sp], #16
    ldp     x25, x26, [sp], #16
    ldp     x27, x28, [sp], #16
    ldr     x29, [sp], #16
    ldr     x30, [sp], #16
    /* The signal handler pushed the interrupted LR and put the resume PC in
       x30, making this frame look like an injected call. Restore the original
       LR for the interrupted function, then branch back through x16 (IP0). */
    mov     x16, x30
    ldr     x30, [sp], #16
    br      x16

#if defined(__linux__)
.section .note.GNU-stack,"",@progbits
#endif
