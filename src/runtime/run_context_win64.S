/*
 * run_context_win64.S — x86-64 context switch for Windows (Win64 ABI)
 *
 * run_context_t layout for Windows x64 (10 GPRs + 10 XMMs = 240 bytes):
 *   offset 0x00: rsp
 *   offset 0x08: rip
 *   offset 0x10: rbx
 *   offset 0x18: rbp
 *   offset 0x20: rdi   (callee-saved on Win64)
 *   offset 0x28: rsi   (callee-saved on Win64)
 *   offset 0x30: r12
 *   offset 0x38: r13
 *   offset 0x40: r14
 *   offset 0x48: r15
 *   offset 0x50: xmm6  (16 bytes)
 *   offset 0x60: xmm7  (16 bytes)
 *   offset 0x70: xmm8  (16 bytes)
 *   offset 0x80: xmm9  (16 bytes)
 *   offset 0x90: xmm10 (16 bytes)
 *   offset 0xA0: xmm11 (16 bytes)
 *   offset 0xB0: xmm12 (16 bytes)
 *   offset 0xC0: xmm13 (16 bytes)
 *   offset 0xD0: xmm14 (16 bytes)
 *   offset 0xE0: xmm15 (16 bytes)
 *
 * Windows x64 ABI: first arg in RCX, second in RDX, third in R8, fourth in R9.
 * Callee-saved: RBX, RBP, RDI, RSI, RSP, R12-R15, XMM6-XMM15.
 */

.text

/*
 * void run_context_switch(run_context_t *from, run_context_t *to)
 *   rcx = from context (save current state here)
 *   rdx = to context (restore state from here)
 */
.globl run_context_switch
run_context_switch:
    /* Save callee-saved GPRs to 'from' */
    movq    %rsp,  0x00(%rcx)
    movq    %rbx,  0x10(%rcx)
    movq    %rbp,  0x18(%rcx)
    movq    %rdi,  0x20(%rcx)
    movq    %rsi,  0x28(%rcx)
    movq    %r12,  0x30(%rcx)
    movq    %r13,  0x38(%rcx)
    movq    %r14,  0x40(%rcx)
    movq    %r15,  0x48(%rcx)

    /* Save return address as resume point */
    leaq    .Lresume_win64(%rip), %rax
    movq    %rax,  0x08(%rcx)

    /* Save callee-saved XMM registers to 'from' */
    movaps  %xmm6,  0x50(%rcx)
    movaps  %xmm7,  0x60(%rcx)
    movaps  %xmm8,  0x70(%rcx)
    movaps  %xmm9,  0x80(%rcx)
    movaps  %xmm10, 0x90(%rcx)
    movaps  %xmm11, 0xA0(%rcx)
    movaps  %xmm12, 0xB0(%rcx)
    movaps  %xmm13, 0xC0(%rcx)
    movaps  %xmm14, 0xD0(%rcx)
    movaps  %xmm15, 0xE0(%rcx)

    /* Restore callee-saved GPRs from 'to' */
    movq    0x10(%rdx), %rbx
    movq    0x18(%rdx), %rbp
    movq    0x20(%rdx), %rdi
    movq    0x28(%rdx), %rsi
    movq    0x30(%rdx), %r12
    movq    0x38(%rdx), %r13
    movq    0x40(%rdx), %r14
    movq    0x48(%rdx), %r15

    /* Restore callee-saved XMM registers from 'to' */
    movaps  0x50(%rdx), %xmm6
    movaps  0x60(%rdx), %xmm7
    movaps  0x70(%rdx), %xmm8
    movaps  0x80(%rdx), %xmm9
    movaps  0x90(%rdx), %xmm10
    movaps  0xA0(%rdx), %xmm11
    movaps  0xB0(%rdx), %xmm12
    movaps  0xC0(%rdx), %xmm13
    movaps  0xD0(%rdx), %xmm14
    movaps  0xE0(%rdx), %xmm15

    /* Restore stack pointer and jump to saved instruction pointer */
    movq    0x00(%rdx), %rsp
    jmpq    *0x08(%rdx)

.Lresume_win64:
    ret

/*
 * void run_context_init(run_context_t *ctx, void *stack_top,
 *                       void (*entry)(void *), void *arg)
 *   rcx = ctx
 *   rdx = stack_top (highest address of stack allocation)
 *   r8  = entry function
 *   r9  = arg
 *
 * Sets up the context so that when switched to, execution starts
 * at a trampoline that calls entry(arg), then falls through to run_g_exit.
 */
.globl run_context_init
run_context_init:
    /* Align stack_top down to 16 bytes */
    andq    $-16, %rdx

    /* Reserve the Win64 shadow space used by calls from the trampoline.
     * The trampoline is entered via jmp rather than call, so it does not need
     * a synthetic return address. Keep rsp 16-byte aligned before each call;
     * callq then gives the callee the ABI-required rsp+8 alignment. */
    subq    $32, %rdx

    /* Store entry and arg in callee-saved registers for the trampoline:
     * r12 = entry function, r13 = arg */
    movq    %rdx, 0x00(%rcx)           /* rsp = adjusted stack top */
    leaq    .Ltrampoline_win64(%rip), %rax
    movq    %rax, 0x08(%rcx)           /* rip = trampoline */
    movq    $0,   0x10(%rcx)           /* rbx = 0 */
    movq    $0,   0x18(%rcx)           /* rbp = 0 */
    movq    $0,   0x20(%rcx)           /* rdi = 0 */
    movq    $0,   0x28(%rcx)           /* rsi = 0 */
    movq    %r8,  0x30(%rcx)           /* r12 = entry function */
    movq    %r9,  0x38(%rcx)           /* r13 = arg */
    movq    $0,   0x40(%rcx)           /* r14 = 0 */
    movq    $0,   0x48(%rcx)           /* r15 = 0 */

    /* Zero XMM save slots */
    xorps   %xmm0, %xmm0
    movaps  %xmm0, 0x50(%rcx)         /* xmm6 */
    movaps  %xmm0, 0x60(%rcx)         /* xmm7 */
    movaps  %xmm0, 0x70(%rcx)         /* xmm8 */
    movaps  %xmm0, 0x80(%rcx)         /* xmm9 */
    movaps  %xmm0, 0x90(%rcx)         /* xmm10 */
    movaps  %xmm0, 0xA0(%rcx)         /* xmm11 */
    movaps  %xmm0, 0xB0(%rcx)         /* xmm12 */
    movaps  %xmm0, 0xC0(%rcx)         /* xmm13 */
    movaps  %xmm0, 0xD0(%rcx)         /* xmm14 */
    movaps  %xmm0, 0xE0(%rcx)         /* xmm15 */
    ret

/*
 * Trampoline: called when a new G is first scheduled.
 * r12 = entry function pointer, r13 = argument.
 * After entry returns, falls through to run_g_exit().
 *
 * Win64 ABI: first parameter goes in rcx, shadow space is already
 * reserved on the stack by run_context_init.
 */
.Ltrampoline_win64:
    movq    %r13, %rcx                 /* arg -> first parameter (Win64: rcx) */
    callq   *%r12                      /* call entry(arg) */
    /* entry returned — clean exit */
    callq   run_g_exit
    /* Should never reach here; run_g_exit does not return */
    ud2
