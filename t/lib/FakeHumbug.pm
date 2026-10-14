package FakeHumbug;

use 5.042;
use warnings;
use JSON::PP ();
use MIME::Base64 ();
use File::Spec;
use OpenAPI::Humbug;
use Exporter qw( import );

our @EXPORT = qw( fake_humbug wire_command reaped fake_pid );

my $fake = File::Spec->rel2abs('t/bin/fake-humbug');

# a client talking to t/bin/fake-humbug in the given init mode
sub fake_humbug ($mode = 'ok', %args) {
  return OpenAPI::Humbug->new(
    spec       => 'corpus/pets.yaml',
    executable => $^X,
    args       => [$fake, $mode],
    %args,
  );
}

# the command line the fake received, decoded, from an echo result
sub wire_command ($result) {
  my $line = MIME::Base64::decode_base64($result->{fake}{line_base64});
  return ($line, JSON::PP->new->utf8->decode($line));
}

# true if the process no longer exists (a zombie still counts as existing)
sub reaped ($pid) {
  return !kill 0, $pid;
}

# run code with FAKE_HUMBUG_PIDFILE set and return the pid the fake wrote
sub fake_pid ($code) {
  my $file = File::Spec->catfile(File::Spec->tmpdir, "fake-humbug-$$-" . int rand 1_000_000);
  local $ENV{FAKE_HUMBUG_PIDFILE} = $file;
  $code->();
  open my $fh, '<', $file or die "$file: $!";
  my $pid = <$fh>;
  close $fh;
  unlink $file;
  return $pid;
}

1;
