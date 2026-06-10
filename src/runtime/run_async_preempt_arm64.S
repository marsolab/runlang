/*
 * run_async_preempt_arm64.S — asynchronous preemption trampoline (aarch64)
 *
 * The SIGURG handler rewrites the interrupted thread's PC to this function,
 * after pushing the interrupted LR at sp-16 and moving the interrupted PC
 * into LR (so the frame looks like an injected call).
 *
 * Because the interruption point is arbitrary, the full register state must
 * be preserved: all GPRs, NZCV condition flags, FPSR/FPCR, and q0-q31.
 * run_yield context-switches and clobbers everything a C call may clobber.
 */

.text
.globl run_async_preempt
#if defined(__APPLE__)
.globl _run_async_preempt
_run_async_preempt:
#endif
run_async_preempt:
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
    /* Condition flags and FP control/status. Loads/stores and address
       arithmetic do not modify NZCV, so reading it here is safe; x9-x11
       were saved above and are free to clobber. */
    mrs     x9, nzcv
    mrs     x10, fpsr
    mrs     x11, fpcr
    stp     x9, x10, [sp, #-16]!
    str     x11, [sp, #-16]!
    /* Full SIMD register file. */
    stp     q30, q31, [sp, #-32]!
    stp     q28, q29, [sp, #-32]!
    stp     q26, q27, [sp, #-32]!
    stp     q24, q25, [sp, #-32]!
    stp     q22, q23, [sp, #-32]!
    stp     q20, q21, [sp, #-32]!
    stp     q18, q19, [sp, #-32]!
    stp     q16, q17, [sp, #-32]!
    stp     q14, q15, [sp, #-32]!
    stp     q12, q13, [sp, #-32]!
    stp     q10, q11, [sp, #-32]!
    stp     q8, q9, [sp, #-32]!
    stp     q6, q7, [sp, #-32]!
    stp     q4, q5, [sp, #-32]!
    stp     q2, q3, [sp, #-32]!
    stp     q0, q1, [sp, #-32]!
    /* Call run_yield() */
#if defined(__APPLE__)
    bl      _run_yield
    bl      _run_async_preempt_done
#else
    bl      run_yield
    bl      run_async_preempt_done
#endif
    /* Restore SIMD registers */
    ldp     q0, q1, [sp], #32
    ldp     q2, q3, [sp], #32
    ldp     q4, q5, [sp], #32
    ldp     q6, q7, [sp], #32
    ldp     q8, q9, [sp], #32
    ldp     q10, q11, [sp], #32
    ldp     q12, q13, [sp], #32
    ldp     q14, q15, [sp], #32
    ldp     q16, q17, [sp], #32
    ldp     q18, q19, [sp], #32
    ldp     q20, q21, [sp], #32
    ldp     q22, q23, [sp], #32
    ldp     q24, q25, [sp], #32
    ldp     q26, q27, [sp], #32
    ldp     q28, q29, [sp], #32
    ldp     q30, q31, [sp], #32
    /* Restore flags and FP control/status */
    ldr     x11, [sp], #16
    ldp     x9, x10, [sp], #16
    msr     nzcv, x9
    msr     fpsr, x10
    msr     fpcr, x11
    /* Restore GPRs */
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
/* Mark stack as non-executable (GNU ld security) */
.section .note.GNU-stack,"",@progbits
#endif
