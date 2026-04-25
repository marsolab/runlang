.text
.globl run_async_preempt
#if defined(__APPLE__)
.globl _run_async_preempt
_run_async_preempt:
#endif
run_async_preempt:
    /* Save all general-purpose registers that normal function calls may touch
       or that run_context_switch would otherwise capture from run_yield. */
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
    /* Call run_yield() */
#if defined(__APPLE__)
    callq   _run_yield
    callq   _run_async_preempt_done
#else
    callq   run_yield
    callq   run_async_preempt_done
#endif
    /* Restore registers */
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
    ret

#if defined(__linux__)
.section .note.GNU-stack,"",@progbits
#endif
