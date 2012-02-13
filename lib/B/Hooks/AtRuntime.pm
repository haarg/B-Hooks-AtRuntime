package B::Hooks::AtRuntime;

use warnings;
use strict;

use XSLoader;
use Exporter        "import";
use Sub::Name       "subname";
use Carp;

BEGIN {
    our $VERSION = "1";
    XSLoader::load __PACKAGE__, $VERSION;
}

our @EXPORT = "at_runtime";
our @EXPORT_OK = qw/at_runtime lex_stuff/;

use constant USE_FILTER =>
    defined $ENV{PERL_B_HOOKS_ATRUNTIME} 
        ? $ENV{PERL_B_HOOKS_ATRUNTIME} eq "filter"
        : not defined &lex_stuff;

if (USE_FILTER) {
    require Filter::Util::Call;

    # This isn't an exact replacement: it inserts the text at the start
    # of the next line, rather than immediately after the current BEGIN.
    #
    # In theory I could use B::Hooks::Parser, which aims to emulate
    # lex_stuff on older perls, but that uses a source filter to ensure
    # PL_linebuf has some extra space in it (since it can't be
    # reallocated without adjusting pointers we can't get to). This
    # means BHP::setup needs to be called at least one source line
    # before we want to insert any text (so the filter has a chance to
    # run), which makes it precisely useless for our purposes :(.

    no warnings "redefine";
    *lex_stuff = subname "lex_stuff", sub {
        my ($str) = @_;

        compiling_string_eval() and croak 
            "Can't stuff into a string eval";

        if (defined(my $extra = remaining_text())) {
            $extra =~ s/\n+\z//;
            carp "Extra text '$extra' after call to lex_stuff";
        }

        Filter::Util::Call::filter_add(sub {
            $_ = $str;
            Filter::Util::Call::filter_del();
            return 1;
        });
    };
}

my @Hooks;

sub replace_run {
    my ($new) = @_;

    # By deleting the stash entry we ensure the only ref to the glob is
    # through the optree it was compiled into. This means that if that
    # optree is ever freed, the glob will disappear along with @hooks
    # and anything closed over by the user's callbacks.
    delete $B::Hooks::AtRuntime::{run};

    no strict "refs";
    $new and *{"run"} = $new->[1];
}

sub clear {
    my ($depth) = @_;
    $Hooks[$depth] = undef;
    replace_run $Hooks[$depth - 1];
}

sub at_runtime (&) {
    my ($cv) = @_;

    USE_FILTER and compiling_string_eval() and croak
        "Can't use at_runtime from a string eval";

    my $depth = count_BEGINs()
        or croak "You must call at_runtime at compile time";

    my $hk;
    unless ($hk = $Hooks[$depth]) {
        # Close over an array of callbacks so we don't need to keep
        # stuffing text into the buffer.
        my @hooks;
        $hk = $Hooks[$depth] = [ 
            \@hooks, 
            subname "run", sub { $_->() for @hooks } 
        ];
        replace_run $hk;

        # This must be all on one line, so we don't mess up perl's idea
        # of the current line number.
        lex_stuff("B::Hooks::AtRuntime::run();" .
            "BEGIN{B::Hooks::AtRuntime::clear($depth)}");
    }

    push @{$$hk[0]}, $cv;
}

1;

=head1 NAME

B::Hooks::AtRuntime - Lower blocks from compile time to runtime

=head1 SYNOPSIS

    # My::Module
    sub import {
        at_runtime { warn "TWO" };
    }

    # elsewhere
    warn "ONE";
    use My::Module;
    warn "THREE";

=head1 DESCRIPTION

This module allows code that runs at compile-time to do something at
runtime. A block passed to C<at_runtime> gets compiled into the code
that's currently compiling, and will be called when control reaches that
point at runtime. In the example in the SYNOPSIS, the warnings will
occur in order, and if that section of code runs more than once, so will
all three warnings.

=head2 C<at_runtime { ... }>

This sets up a block to be called at runtime. It must be called from
within a C<BEGIN> block or C<use>, otherwise there will be no compiling
code to insert into. The innermost enclosing C<BEGIN> block, which would
normally be invisible once the section of code it is in has been
compiled, will effectively leave behind a call to the given block. For
example, this

    BEGIN { warn "ONE" }    warn "one";
    BEGIN { warn "TWO";     at_runtime { warn "two" }; }

will warn "ONE TWO one two", with the last warning 'lowered' out of the
C<BEGIN> block and back into the runtime control flow.

This applies even if calls to other subs intervene between C<BEGIN> and
C<at_runtime>. The lowered block is always inserted at the innermost
point where perl is still compiling, so something like this

    # My::Module
    sub also_at_runtime { 
        my ($msg) = @_; 
        at_runtime { warn $msg };
    }

    sub import {
        my ($class, $one, $two) = @_;
        at_runtime { warn $one };
        also_at_runtime $two;
    }

    # 
    warn "one";
    BEGIN { at_runtime { warn "two" } }
    BEGIN { My::Module::also_at_runtime "three" }
    use My::Module "four", "five";

will still put the warnings in order.

=head2 Object lifetimes

C<at_runtime> is careful to make sure the anonymous sub passed to it
doesn't live any longer than it has to. It, and any lexicals it has
closed over, will be destroyed when the optree it has been compiled into
is destroyed: for code outside any sub, this is when the containing file
or eval finishes executing; for named subs, this is when the sub is un-
or redefined; and for anonymous subs, this is not until both the code
containing the C<sub { }> expression and all instances generated by that
expression have been destroyed.

=head2 C<B::Hooks::AtRuntime::run>

If you look at a stack trace from within an C<at_runtime> block, you
will see there is a frame for a sub called C<B::Hooks::AtRuntime::run>
between your anonymous sub and the point where it was inserted. This is
not a function you can call yourself (it is set up and destroyed as part
of the lowering-to-runtime mechanism), but if for instance you wanted to
use something like L<Scope::Upper> to manipulate the runtime scope you
need to be aware it will be there.

=head2 C<lex_stuff I<$text>>

This is the function underlying C<at_runtime>. Under perl 5.12 and
later, this is just a Perl wrapper for the core function
L<lex_stuff_sv|perlapi/lex_stuff_sv>. Under earlier versions it is
implemented with a source filter, with some limitations, see L<CAVEATS>
below.

This function pushes text into perl's line buffer, at the point perl is
currently compiling. You should probably not try to push too much at
once without giving perl a chance to compile it. If C<$text> contains
newlines, they will affect perl's idea of the current line number. You
probably shouldn't use this function at all.

=head1 CAVEATS

=head2 Perls before 5.12

Versions of perl before 5.12.0 don't have the C<lex_stuff_sv> function,
and don't export enough for it to be possible to emulate it entirely.
(L<B::Hooks::Parser> gets as close as it can, and just exactly doesn't
quite do what we need for C<at_runtime>.) This means our C<lex_stuff>
has to fall back to using a source filter to insert the text, which has
a couple of important limitations.

=over 4

=item * You cannot stuff text into a string C<eval>.

String evals aren't affected by source filters, so the stuffed text
would end up getting inserted into the innermost compiling scope that
B<wasn't> a string eval. Since this would be rather confusing, and
different from what 5.12 does, C<lex_stuff> and C<at_runtime> will croak
if you try to use them to affect a string eval.

=item * Stuffed text appears at the start of the next line.

This, unfortunately, is rather annoying. With a filter, the earliest
point at which we can insert text is the start of the next line. This
means that if there is any text between the closing brace of the
C<BEGIN> block or the semicolon of the C<use> that caused the insertion,
and the end of the line, the insertion will certainly be in the wrong
place and probably cause a syntax error. 

C<lex_stuff> (and, therefore, C<at_runtime>) will issue a warning if
this is going to happen (specifically, if there are any non-space
non-comment characters between the point where we want to insert and the
point we're forced to settle for), but this may not be something you can
entirely control. If you are writing a module like the examples above
which calls C<at_runtime> from its C<import> method, what matters is
that B<users of your module> not put anything on a line after your
module's C<use> statement.

=back

If you want to use the filter implementation on perl 5.12 (for testing),
set C<PERL_B_HOOKS_ATRUNTIME=filter> in the environment. If the filter
implementation is in use, C<B::Hooks::AtRuntime::USE_FILTER> will be
true.

=head1 SEE ALSO

L<B::Hooks::Parser> will insert text 'here' in perls before 5.12, but
requires a setup step at least one source line in advance.

L<Hook::AfterRuntime> uses it to implement something somewhat similar to
this module.

L<Scope::Upper> is useful for escaping (in a limited fashion) from
C<at_runtime> up to the scope it was inserted into.

L<Filter::Util::Call> is the generic interface to the source filtering
mechanism.

=head1 AUTHOR

Ben Morrow <ben@morrow.me.uk>

=head1 BUGS

Please report any bugs to <bug-B-Hooks-AtRuntime@rt.cpan.org>.

=head1 ACKNOWLEDGEMENTS

Zefram's work on the core lexer API made this module enormously easier.

=head1 COPYRIGHT

Copyright 2012 Ben Morrow.

Released under the 2-clause BSD licence.

=cut
