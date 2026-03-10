/*
 * run_context_amd64.S — x86-64 context switch for Linux/macOS (System V ABI)
 *
 * run_context_t layout (8 fields × 8 bytes = 64 bytes):
 *   offset 0x00: rsp
 *   offset 0x08: rip
 *   offset 0x10: rbx
 *   offset 0x18: rbp
 *   offset 0x20: r12
 *   offset 0x28: r13
 *   offset 0x30: r14
 *   offset 0x38: r15
 */

.text

/*
 * void run_context_switch(run_context_t *from, run_context_t *to)
 *   rdi = from context (save current state here)
 *   rsi = to context (restore state from here)
 */
.globl run_context_switch
#if defined(__APPLE__)
.globl _run_context_switch
_run_context_switch:
#endif
run_context_switch:
    /* Save callee-saved registers to 'from' */
    movq    %rsp,  0x00(%rdi)
    movq    %rbx,  0x10(%rdi)
    movq    %rbp,  0x18(%rdi)
    movq    %r12,  0x20(%rdi)
    movq    %r13,  0x28(%rdi)
    movq    %r14,  0x30(%rdi)
    movq    %r15,  0x38(%rdi)
    /* Save return address as resume point */
    leaq    .Lresume(%rip), %rax
    movq    %rax,  0x08(%rdi)

    /* Restore callee-saved registers from 'to' */
    movq    0x10(%rsi), %rbx
    movq    0x18(%rsi), %rbp
    movq    0x20(%rsi), %r12
    movq    0x28(%rsi), %r13
    movq    0x30(%rsi), %r14
    movq    0x38(%rsi), %r15
    movq    0x00(%rsi), %rsp
    /* Jump to saved instruction pointer */
    jmpq    *0x08(%rsi)

.Lresume:
    ret

/*
 * void run_context_init(run_context_t *ctx, void *stack_top,
 *                       void (*entry)(void *), void *arg)
 *   rdi = ctx
 *   rsi = stack_top (highest address of stack allocation)
 *   rdx = entry function
 *   rcx = arg
 *
 * Sets up the context so that when switched to, execution starts
 * at a trampoline that calls entry(arg), then falls through to run_g_exit.
 */
.globl run_context_init
#if defined(__APPLE__)
.globl _run_context_init
_run_context_init:
#endif
run_context_init:
    /* Align stack_top down to 16 bytes */
    andq    $-16, %rsi

    /* Reserve space: return address for alignment */
    subq    $8, %rsi

    /* The trampoline will be the initial rip. Store entry and arg in
     * callee-saved registers (r12=entry, r13=arg) so the trampoline
     * can access them after context switch. */
    movq    %rsi, 0x00(%rdi)       /* rsp = adjusted stack top */
    leaq    .Ltrampoline(%rip), %rax
    movq    %rax, 0x08(%rdi)       /* rip = trampoline */
    movq    $0,   0x10(%rdi)       /* rbx = 0 */
    movq    $0,   0x18(%rdi)       /* rbp = 0 */
    movq    %rdx, 0x20(%rdi)       /* r12 = entry function */
    movq    %rcx, 0x28(%rdi)       /* r13 = arg */
    movq    $0,   0x30(%rdi)       /* r14 = 0 */
    movq    $0,   0x38(%rdi)       /* r15 = 0 */
    ret

/*
 * Trampoline: called when a new G is first scheduled.
 * r12 = entry function pointer, r13 = argument.
 * After entry returns, falls through to run_g_exit().
 */
.Ltrampoline:
    movq    %r13, %rdi             /* arg -> first parameter */
    callq   *%r12                  /* call entry(arg) */
    /* entry returned — clean exit */
#if defined(__APPLE__)
    callq   _run_g_exit
#else
    callq   run_g_exit
#endif
    /* Should never reach here; run_g_exit does not return */
    ud2

#if defined(__linux__)
/* Mark stack as non-executable (GNU ld security) */
.section .note.GNU-stack,"",@progbits
#endif
