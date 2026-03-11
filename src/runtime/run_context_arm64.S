/*
 * run_context_arm64.S — AArch64 context switch for Linux/macOS
 *
 * run_context_t layout for ARM64 (14 fields x 8 bytes = 112 bytes):
 *   offset 0x00: sp
 *   offset 0x08: lr   (x30, link register / return address)
 *   offset 0x10: x19
 *   offset 0x18: x20
 *   offset 0x20: x21
 *   offset 0x28: x22
 *   offset 0x30: x23
 *   offset 0x38: x24
 *   offset 0x40: x25
 *   offset 0x48: x26
 *   offset 0x50: x27
 *   offset 0x58: x28
 *   offset 0x60: fp   (x29, frame pointer)
 *   offset 0x68: (padding/unused)
 *
 * Note: on ARM64, the run_context_t struct differs from x86-64.
 * The scheduler.h uses a union or conditional compilation to handle this.
 * For now, this assembly file matches the x86-64 struct layout using
 * the first 8 slots differently:
 *   slot 0 (0x00): sp   (rsp on x86)
 *   slot 1 (0x08): lr   (rip on x86)
 *   slot 2 (0x10): x19  (rbx on x86)
 *   slot 3 (0x18): x20  (rbp on x86)
 *   slot 4 (0x20): x21  (r12 on x86)
 *   slot 5 (0x28): x22  (r13 on x86)
 *   slot 6 (0x30): x23  (r14 on x86)
 *   slot 7 (0x38): x24  (r15 on x86)
 *   Extended fields (beyond the base 8-slot struct):
 *   slot 8  (0x40): x25
 *   slot 9  (0x48): x26
 *   slot 10 (0x50): x27
 *   slot 11 (0x58): x28
 *   slot 12 (0x60): fp (x29)
 */

.text

/*
 * void run_context_switch(run_context_t *from, run_context_t *to)
 *   x0 = from context (save current state here)
 *   x1 = to context (restore state from here)
 */
.globl run_context_switch
#if defined(__APPLE__)
.globl _run_context_switch
_run_context_switch:
#endif
run_context_switch:
    /* Save callee-saved registers to 'from' */
    mov     x2, sp
    str     x2,       [x0, #0x00]    /* sp */
    str     x30,      [x0, #0x08]    /* lr (return address) */
    stp     x19, x20, [x0, #0x10]
    stp     x21, x22, [x0, #0x20]
    stp     x23, x24, [x0, #0x30]
    stp     x25, x26, [x0, #0x40]
    stp     x27, x28, [x0, #0x50]
    str     x29,      [x0, #0x60]    /* fp */

    /* Restore callee-saved registers from 'to' */
    ldr     x2,       [x1, #0x00]    /* sp */
    mov     sp, x2
    ldr     x30,      [x1, #0x08]    /* lr */
    ldp     x19, x20, [x1, #0x10]
    ldp     x21, x22, [x1, #0x20]
    ldp     x23, x24, [x1, #0x30]
    ldp     x25, x26, [x1, #0x40]
    ldp     x27, x28, [x1, #0x50]
    ldr     x29,      [x1, #0x60]    /* fp */

    ret     /* return to restored lr */

/*
 * void run_context_init(run_context_t *ctx, void *stack_top,
 *                       void (*entry)(void *), void *arg)
 *   x0 = ctx
 *   x1 = stack_top
 *   x2 = entry function
 *   x3 = arg
 */
.globl run_context_init
#if defined(__APPLE__)
.globl _run_context_init
_run_context_init:
#endif
run_context_init:
    /* Align stack_top down to 16 bytes */
    and     x1, x1, #~15

    /* Reserve 16 bytes for alignment */
    sub     x1, x1, #16

    /* Store entry and arg in callee-saved registers for the trampoline:
     * x19 = entry function, x20 = arg */
    str     x1,  [x0, #0x00]         /* sp */
    adr     x4, .Ltrampoline_arm64
    str     x4,  [x0, #0x08]         /* lr = trampoline */
    str     x2,  [x0, #0x10]         /* x19 = entry */
    str     x3,  [x0, #0x18]         /* x20 = arg */
    /* Zero remaining callee-saved regs */
    stp     xzr, xzr, [x0, #0x20]   /* x21, x22 */
    stp     xzr, xzr, [x0, #0x30]   /* x23, x24 */
    stp     xzr, xzr, [x0, #0x40]   /* x25, x26 */
    stp     xzr, xzr, [x0, #0x50]   /* x27, x28 */
    str     xzr, [x0, #0x60]         /* fp */
    ret

/*
 * Trampoline: called when a new G is first scheduled.
 * x19 = entry function, x20 = arg
 */
.Ltrampoline_arm64:
    mov     x0, x20                   /* arg -> first parameter */
    blr     x19                       /* call entry(arg) */
    /* entry returned -- clean exit */
#if defined(__APPLE__)
    bl      _run_g_exit
#else
    bl      run_g_exit
#endif
    /* Should never reach here */
    brk     #0

#if defined(__linux__)
/* Mark stack as non-executable */
.section .note.GNU-stack,"",@progbits
#endif
