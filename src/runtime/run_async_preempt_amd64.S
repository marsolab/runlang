/*
 * run_async_preempt_amd64.S — asynchronous preemption trampoline (x86-64)
 *
 * The SIGURG handler rewrites the interrupted thread's PC to this function,
 * pushing the original PC as a return address BELOW the System V red zone
 * (the 128 bytes under rsp belong to the interrupted leaf frame and must not
 * be touched).
 *
 * Because the interruption point is arbitrary, the full caller-visible
 * register state must be preserved: all GPRs, RFLAGS, MXCSR, and xmm0-15.
 * run_yield context-switches and clobbers everything a C call may clobber.
 */

.text
.globl run_async_preempt
#if defined(__APPLE__)
.globl _run_async_preempt
_run_async_preempt:
#endif
run_async_preempt:
    /* Flags first — pushes do not modify RFLAGS, sub does. */
    pushfq
    pushq   %rax
    pushq   %rcx
    pushq   %rdx
    pushq   %rsi
    pushq   %rdi
    pushq   %r8
    pushq   %r9
    pushq   %r10
    pushq   %r11
    pushq   %rbx
    pushq   %rbp
    pushq   %r12
    pushq   %r13
    pushq   %r14
    pushq   %r15
    /* FP state: 16 xmm registers + MXCSR. rsp may have any alignment here
       (arbitrary interruption point), so use unaligned stores. */
    subq    $272, %rsp
    movups  %xmm0,   0(%rsp)
    movups  %xmm1,  16(%rsp)
    movups  %xmm2,  32(%rsp)
    movups  %xmm3,  48(%rsp)
    movups  %xmm4,  64(%rsp)
    movups  %xmm5,  80(%rsp)
    movups  %xmm6,  96(%rsp)
    movups  %xmm7, 112(%rsp)
    movups  %xmm8, 128(%rsp)
    movups  %xmm9, 144(%rsp)
    movups  %xmm10, 160(%rsp)
    movups  %xmm11, 176(%rsp)
    movups  %xmm12, 192(%rsp)
    movups  %xmm13, 208(%rsp)
    movups  %xmm14, 224(%rsp)
    movups  %xmm15, 240(%rsp)
    stmxcsr 256(%rsp)
    /* Call run_yield() */
#if defined(__APPLE__)
    callq   _run_yield
    callq   _run_async_preempt_done
#else
    callq   run_yield
    callq   run_async_preempt_done
#endif
    /* Restore FP state */
    ldmxcsr 256(%rsp)
    movups    0(%rsp), %xmm0
    movups   16(%rsp), %xmm1
    movups   32(%rsp), %xmm2
    movups   48(%rsp), %xmm3
    movups   64(%rsp), %xmm4
    movups   80(%rsp), %xmm5
    movups   96(%rsp), %xmm6
    movups  112(%rsp), %xmm7
    movups  128(%rsp), %xmm8
    movups  144(%rsp), %xmm9
    movups  160(%rsp), %xmm10
    movups  176(%rsp), %xmm11
    movups  192(%rsp), %xmm12
    movups  208(%rsp), %xmm13
    movups  224(%rsp), %xmm14
    movups  240(%rsp), %xmm15
    addq    $272, %rsp
    /* Restore GPRs and flags */
    popq    %r15
    popq    %r14
    popq    %r13
    popq    %r12
    popq    %rbp
    popq    %rbx
    popq    %r11
    popq    %r10
    popq    %r9
    popq    %r8
    popq    %rdi
    popq    %rsi
    popq    %rdx
    popq    %rcx
    popq    %rax
    popfq
    /* Pop the return PC and discard the red-zone gap the handler skipped
       (ret imm16 adds imm to rsp AFTER popping the return address). */
    retq    $128

#if defined(__linux__)
.section .note.GNU-stack,"",@progbits
#endif
