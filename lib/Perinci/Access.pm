package Perinci::Access;

1;
# ABSTRACT: Use Rinci access protocol (Riap) to access Perl code

=head1 SYNOPSIS

 use Perinci::Access;
 my $pa = Perinci::Access->new();

 # list all packages
 my $res = $pa->request(list => '/', {type=>'package', recursive=>1});
 die "Failed: $res->[0] - $res->[1]" unless $res->[0] == 200;

 # get summary for each package
 for my $uri (@{$res->[2]}) {
     $res = $pa->request(meta => $uri);
     print "$uri - $res->[2]{summary}\n";
 }


=head1 DESCRIPTION

This module implements Rinci access protocol (L<Riap>) to access local Perl
code.


=head1 SEE ALSO

L<Riap>, L<Rinci>

=cut
