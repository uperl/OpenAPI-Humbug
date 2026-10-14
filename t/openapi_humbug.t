use Test2::V0 -no_srand => 1;
use 5.042;
use lib 't/lib';
use Path::Tiny qw( path );
use OpenAPI::Humbug;
use FakeHumbug;

subtest 'initialize, validate, close' => sub {
  my $humbug = fake_humbug();
  isa_ok $humbug, 'OpenAPI::Humbug';

  is $humbug->specification, { openapi_version => '3.1.0', title => 'Fake', spec_path => path('corpus/pets.yaml')->absolute->stringify },
    'specification, with the spec path made absolute';
  is $humbug->limits, { max_body_bytes => 16, max_future_thing => 7 }, 'limits, unknown keys kept';
  is $humbug->implementation, { name => 'fake-humbug', version => '0.0.1' }, 'implementation';

  my $pid = child_pid($humbug);

  my $result = $humbug->validate(request => { method => 'GET', url => 'https://api.example.test/pets/1' });
  is $result, hash {
    field valid          => T();
    field complete       => T();
    field has_violations => F();
    field request        => hash { field status => 'valid'; etc };
    field response       => hash { field status => 'skipped'; etc };
    etc;
  }, 'result';

  for my $n (2..20) {
    my $r = $humbug->validate(request => { method => 'GET', url => "https://api.example.test/pets/$n" });
    my(undef, $command) = wire_command($r);
    is $command->{id}, $n + 1, "command $n has id @{[ $n + 1 ]}" if $n == 2 || $n == 20;
  }
  is child_pid($humbug), $pid, 'one child for all commands';

  ok $humbug->close, 'close reports a clean exit';
  ok reaped($pid), 'child reaped';
  ok $humbug->close, 'second close is harmless';

  my $error = dies { $humbug->validate(request => { method => 'GET', url => 'x' }) };
  isa_ok $error, 'OpenAPI::Humbug::Error';
  is $error->kind, 'closed', 'validate after close';
};

subtest 'ids are monotonically increasing integers' => sub {
  my $humbug = fake_humbug();
  my @ids = map {
    my(undef, $command) = wire_command($humbug->validate(request => { method => 'GET', url => 'https://x/' }));
    $command->{id};
  } 1..3;
  is \@ids, [2, 3, 4], 'initialize is 1, then 2, 3, 4';
  $humbug->close;
};

subtest 'minimal initialize result' => sub {
  my $humbug = fake_humbug('minimal');
  is $humbug->limits, U(), 'no limits';
  is $humbug->implementation, U(), 'no implementation';
  is $humbug->specification->{title}, 'Fake', 'specification';
  $humbug->close;
};

subtest 'invalid, incomplete and unknown fields are results' => sub {
  my $humbug = fake_humbug();

  my $invalid = $humbug->validate(request => { method => 'GET', url => 'fake:invalid' });
  is $invalid->{valid}, F(), 'invalid is a result with valid false';
  is $invalid->{has_violations}, T(), 'has_violations';
  is $invalid->{request}{diagnostics}[0]{code}, 'schema.type', 'diagnostic';

  my $incomplete = $humbug->validate(request => { method => 'GET', url => 'fake:incomplete' });
  is $incomplete, hash {
    field valid          => F();
    field complete       => F();
    field has_violations => F();
    field future_field   => { nested => [1, 2] };
    field request => hash {
      field status => 'incomplete';
      field diagnostics => [
        hash {
          field code          => 'validation.incomplete';
          field detail        => { reason => 'body.something_new' };
          field suppressed_by => U();
          etc;
        },
        hash {
          field code          => 'future.code';
          field suppressed_by => 'd1';
          field caused_by     => 'd1';
          field brand_new     => ['a'];
          etc;
        },
      ];
      etc;
    };
    etc;
  }, 'incomplete result with unknown codes, reasons and fields passed through';

  ok $humbug->close, 'close';
};

subtest 'sidecar error is an exception, and the client stays usable' => sub {
  my $humbug = fake_humbug();
  my $error = dies { $humbug->validate(request => { method => 'GET', url => 'fake:error' }) };
  isa_ok $error, 'OpenAPI::Humbug::Error';
  is $error->kind, 'sidecar', 'kind';
  is $error->code, 'validator.unsupported_input', 'code';
  is $error->message, 'header name is not a token', 'message';
  is $error->error, { code => 'validator.unsupported_input', message => 'header name is not a token', future => 1 }, 'whole error object';

  ok lives { $humbug->validate(request => { method => 'GET', url => 'https://x/' }) }, 'still usable';
  ok $humbug->close, 'close';
};

subtest 'initialize error' => sub {
  my $error;
  my $pid = fake_pid(sub { $error = dies { fake_humbug('error') } });
  isa_ok $error, 'OpenAPI::Humbug::Error';
  is $error->kind, 'sidecar', 'kind';
  is $error->code, 'spec.invalid', 'code';
  ok reaped($pid), 'child reaped after failed initialize';
};

subtest 'initialize result without specification' => sub {
  my $error;
  my $pid = fake_pid(sub { $error = dies { fake_humbug('bad_result') } });
  is $error->kind, 'protocol', 'kind';
  is $error->code, 'client.unexpected_reply', 'code';
  ok reaped($pid), 'child reaped';
};

subtest 'child exits during initialize' => sub {
  my $error;
  my $pid = fake_pid(sub { $error = dies { fake_humbug('exit') } });
  is $error->kind, 'transport', 'kind';
  is $error->code, 'client.eof', 'code';
  ok reaped($pid), 'child reaped';
};

subtest 'initialize timeout' => sub {
  my $error;
  my $pid = fake_pid(sub { $error = dies { fake_humbug('hang', timeout => 0.5) } });
  is $error->kind, 'timeout', 'kind';
  is $error->code, 'client.timeout', 'code';
  ok reaped($pid), 'child terminated and reaped';
};

subtest 'noisy stderr during initialize' => sub {
  my $humbug = fake_humbug('noisy', max_stderr_bytes => 1000);
  is length($humbug->stderr), 1000, 'stderr drained and bounded';
  like $humbug->stderr, qr/^x+\n$/, 'keeps the tail';
  ok $humbug->close, 'close';
};

subtest 'executable discovery' => sub {
  my $error = dies { OpenAPI::Humbug->new(spec => 'corpus/pets.yaml', executable => '/nonexistent/humbug') };
  is $error->kind, 'transport', 'missing path';
  is $error->code, 'client.spawn_failed', 'code';

  {
    local $ENV{PATH} = '/nonexistent';
    $error = dies { OpenAPI::Humbug->new(spec => 'corpus/pets.yaml') };
    is $error->code, 'client.spawn_failed', 'not in PATH';
  }

  my $perl = path($^X);
  my $file = $perl->basename;
  {
    local $ENV{PATH} = $perl->parent->stringify;
    my $humbug = OpenAPI::Humbug->new(
      spec       => 'corpus/pets.yaml',
      executable => $file,
      args       => [path('t/bin/fake-humbug')->absolute->stringify],
    );
    ok $humbug->validate(request => { method => 'GET', url => 'https://x/' })->{valid}, 'found in PATH';
    $humbug->close;
  }

  # never through a shell: a name with shell metacharacters is just a (missing) file
  $error = dies { OpenAPI::Humbug->new(spec => 'corpus/pets.yaml', executable => './humbug; touch oops') };
  is $error->code, 'client.spawn_failed', 'metacharacters are not interpreted';
  ok !-e 'oops', 'no shell ran';
};

subtest 'imported functions and constants are not methods' => sub {
  ok !OpenAPI::Humbug->can($_), "no $_ method" for qw( which any encode_base64 SHUTDOWN_GRACE FAILURE_GRACE KILL_GRACE CHUNK );
};

subtest 'destroy cleans up' => sub {
  my $pid;
  {
    my $humbug = fake_humbug();
    $pid = child_pid($humbug);
  }
  ok reaped($pid), 'child reaped on destroy';
};

subtest 'forked copy leaves the child alone' => sub {
  my $humbug = fake_humbug();
  my $child = fork // die "fork: $!";
  if($child == 0) {
    my $error = eval { $humbug->validate(request => { method => 'GET', url => 'https://x/' }); 1 } ? undef : $@;
    undef $humbug;
    POSIX::_exit(ref $error && $error->kind eq 'closed' ? 0 : 1);
  }
  waitpid $child, 0;
  is $? >> 8, 0, 'child process cannot use the client';
  ok $humbug->validate(request => { method => 'GET', url => 'https://x/' })->{valid}, 'parent still can';
  ok $humbug->close, 'close';
};

done_testing;
