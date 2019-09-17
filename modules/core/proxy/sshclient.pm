# 
# Copyright 2019 Centreon (http://www.centreon.com/)
#
# Centreon is a full-fledged industry-strength solution that meets
# the needs in IT infrastructure and application monitoring for
# service performance.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

package modules::core::proxy::sshclient;

use base qw(Libssh::Session);

use strict;
use warnings;
use Libssh::Sftp qw(:all);
use POSIX;
use centreon::misc::misc;
use File::Basename;

sub new {
    my ($class, %options) = @_;
    my $self = $class->SUPER::new(%options);
    bless $self, $class;

    $self->{save_options} = {};
    $self->{logger} = $options{logger};
    $self->{sftp} = undef;
    return $self;
}

sub open_session {
    my ($self, %options) = @_;

    $self->{save_options} = { %options };
    if ($self->options(host => $options{ssh_host}, port => $options{ssh_port}, user => $options{ssh_username}) != Libssh::Session::SSH_OK) {
        $self->{logger}->writeLogError('[proxy] -sshclient- options method: ' . $self->error());
        return -1;
    }

    if ($self->connect(SkipKeyProblem => $options{strict_serverkey_check}) != Libssh::Session::SSH_OK) {
        $self->{logger}->writeLogError('[proxy] -sshclient- connect method: ' . $self->error());
        return -1;
    }

    if ($self->auth_publickey_auto() != Libssh::Session::SSH_AUTH_SUCCESS) {
        $self->{logger}->writeLogInfo('[proxy] -sshclient- auth publickey auto failure: ' . $self->error(GetErrorSession => 1));
        if (!defined($options{ssh_password}) || $options{ssh_password} eq '') {
            $self->{logger}->writeLogError('[proxy] -sshclient- auth issue: no password');
            return -1;
        }
        if ($self->auth_password(password => $options{ssh_password}) != Libssh::Session::SSH_AUTH_SUCCESS) {
            $self->{logger}->writeLogError('[proxy] -sshclient- auth issue: ' . $self->error(GetErrorSession => 1));
            return -1;
        }
    }

    $self->{logger}->writeLogInfo('[proxy] -sshclient- authentification succeed');

    $self->{sftp} = Libssh::Sftp->new(session => $self);
    if (!defined($self->{sftp})) {
        $self->{logger}->writeLogError('[proxy] -sshclient- cannot init sftp: ' . Libssh::Sftp::error());
        return -1;
    }

    return 0;
}

sub local_command {
    my ($self, %options) = @_;

    my ($error, $stdout, $exit_code) = centreon::misc::misc::backtick(
        command => $options{command},
        timeout => (defined($options{timeout})) ? $options{timeout} : 120,
        wait_exit => 1,
        redirect_stderr => 1,
        logger => $self->{logger}
    );
    if ($error <= -1000) {
        return (-1, { message => "command '$options{command}' execution issue: $stdout" });
    }
    if ($exit_code != 0) {
        return (-1, { message => "command '$options{command}' execution issue ($exit_code): $stdout" });
    }
    return 0;
}

sub ping {
    my ($self, %options) = @_;

    if ($self->is_connected()) {
        return 0;
    }

    return -1;
}

sub action_command {
    my ($self, %options) = @_;

    if (!defined($options{data}->{content}->{command}) || $options{data}->{content}->{command} eq '') {
        $self->{logger}->writeLogError('[proxy] -sshclient- action_command: need command');
        return (-1, { message => 'please set command' });
    }

    my $timeout = defined($options{data}->{content}->{timeout}) && $options{data}->{content}->{timeout} =~ /(\d+)/ ? $1 : 60;
    my $timeout_nodata = defined($options{data}->{content}->{timeout_nodata}) && $options{data}->{content}->{timeout_nodata} =~ /(\d+)/ ? $1 : 30;

    my $ret = $self->execute_simple(cmd => $options{data}->{content}->{command}, timeout => $timeout, timeout_nodata => $timeout_nodata);
    my ($code, $data) = (0, {});
    if ($ret->{exit} == Libssh::Session::SSH_OK) {
        $data->{message} = "command '$options{data}->{content}->{command}' had finished successfuly";
        $data->{exit_code} = $ret->{exit_code};
        $data->{stdout} = $ret->{stdout};
        $data->{stderr} = $ret->{stderr};
    } elsif ($ret->{exit} == Libssh::Session::SSH_AGAIN) { # AGAIN means timeout
        $code = -1;
        $data->{message} = "command '$options{data}->{content}->{command}' had timeout";
        $data->{exit_code} = $ret->{exit_code};
        $data->{stdout} = $ret->{stdout};
        $data->{stderr} = $ret->{stderr};
    } else {
        return (-1, { message => $self->error(GetErrorSession => 1) });
    }

    return ($code, $data);
}

sub action_enginecommand {
    my ($self, %options) = @_;

    if (!defined($options{data}->{content}->{command}) || $options{data}->{content}->{command} eq '') {
        $self->{logger}->writeLogError('[proxy] -sshclient- action_enginecommand: need command');
        return (-1, { message => 'please set command' });
    }
    if (!defined($options{data}->{content}->{engine_pipe}) || $options{data}->{content}->{engine_pipe} eq '') {
        $self->{logger}->writeLogError('[proxy] -sshclient- action_enginecommand: need engine_pipe');
        return (-1, { message => 'please set engine_pipe' });
    }

    chomp $options{data}->{content}->{command};
    my $ret = $self->{sftp}->stat_file(file => $options{data}->{content}->{engine_pipe});
    if (!defined($ret)) {
        return (-1, { message => "cannot stat file '$options{data}->{content}->{engine_pipe}': " . $self->{sftp}->get_msg_error() });
    }

    if ($ret->{type} != SSH_FILEXFER_TYPE_SPECIAL) {
        return (-1, { message => "stat file '$options{data}->{content}->{engine_pipe}' is not a pipe file" });
    }

    my $file = $self->{sftp}->open(file => $options{data}->{content}->{engine_pipe}, accesstype => O_WRONLY|O_APPEND);
    if (!defined($file)) {
        return (-1, { message => "cannot open stat file '$options{data}->{content}->{engine_pipe}': " . $self->{sftp}->error() });
    }
    if ($self->{sftp}->write(handle_file => $file, data => $options{data}->{content}->{command} . "\n") != Libssh::Session::SSH_OK) {
        return (-1, { message => "cannot write stat file '$options{data}->{content}->{engine_pipe}': " . $self->{sftp}->error() });
    }

    $self->{logger}->writeLogDebug("[proxy] -sshclient- action_enginecommand '" . $options{data}->{content}->{command} . "' succeeded");
    return (0, { message => 'send enginecommand succeeded' });
}

sub action_remotecopy {
    my ($self, %options) = @_;
    
    if (!defined($options{data}->{content}->{source}) || $options{data}->{content}->{source} eq '') {
        $self->{logger}->writeLogError('[proxy] -sshclient- action_remotecopy: need source');
        return (-1, { message => 'please set source' });
    }
    if (!defined($options{data}->{content}->{destination}) || $options{data}->{content}->{destination} eq '') {
        $self->{logger}->writeLogError('[proxy] -sshclient- action_remotecopy: need destination');
        return (-1, { message => 'please set destination' });
    }

    my ($code, $message, $data);

    my $srcname;
    my $localsrc = $options{data}->{content}->{source};
    my $src = $options{data}->{content}->{source};
    my ($dst, $dst_sftp) = ($options{data}->{content}->{destination}, $options{data}->{content}->{destination});
    if ($options{target_direct} == 0) {
        $dst = $src;
        $dst_sftp = $src;
    }    

    if (-f $options{data}->{content}->{source}) {
        $localsrc = $src;
        $srcname = File::Basename::basename($src);
        $dst_sftp .= $srcname if ($dst =~ /\/$/);
    } elsif (-d $options{data}->{content}->{source}) {
        $srcname = (defined($options{data}->{content}->{type}) ? $options{data}->{content}->{type} : 'tmp') . '-' . $options{target} . '.tar.gz';
        $localsrc = $options{data}->{content}->{cache_dir} . '/' . $srcname; 
        $dst_sftp = $options{data}->{content}->{cache_dir} . '/' . $srcname;

        ($code, $message) = $self->local_command(command => "tar czf $localsrc -C '" . $src . "' .");
        return ($code, $message) if ($code == -1);
    } else {
        return (-1, { message => 'unknown source' });
    }

    if (($code = $self->{sftp}->copy_file(src => $localsrc, dst => $dst_sftp)) == -1) {
        return (-1, { message => "cannot sftp copy file : " . $self->{sftp}->error() });
    }

    if (-d $options{data}->{content}->{source}) {
        ($code, $data) = $self->action_command(
            data => {
                content => { command => "tar zxf $dst_sftp -C '" . $dst  .  "' ." }
            },
        );
        return ($code, $data) if ($code == -1);
    }

    if (defined($options{data}->{content}->{type}) && $options{target_direct} == 0) {
        # for remote server: ask in centcore
    }

    return (0, { message => 'send remotecopy succeeded' });
}

sub action {
    my ($self, %options) = @_;

    $self->test_connection();
    my $func = $self->can('action_' . lc($options{action}));
    if (defined($func)) {
        return $func->(
            $self,
            data => $options{data},
            target_direct => $options{target_direct},
            target => $options{target}
        );
    }

    $self->{logger}->writeLogError('[proxy] -sshclient- unsupported action ' . $options{action});
    return (-1, { message => 'unsupported action' });
}

sub test_connection {
    my ($self, %options) = @_;

    if ($self->is_connected() == 0) {
        $self->disconnect();
        $self->open_session(%{$self->{save_options}});
    }
}

sub close {
    my ($self, %options) = @_;
    
    # to be compatible with zmq close class
}

1;
