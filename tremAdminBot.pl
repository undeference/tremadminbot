#!/usr/bin/perl
#    TremAdminBot: A bot that provides some helper functions for Tremulous server administration
#    By Chris "Lakitu7" Schwarz, lakitu7@mercenariesguild.net
#
#    This file is part of TremAdminBot
#
#    TremAdminBot is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    TremAdminBot is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with TremAdminBot.  If not, see <http://www.gnu.org/licenses/>.

use common::sense;
use DBI;
use Socket;
use Socket6;
use Data::Dumper;
use Text::ParseWords;
use enum;
use FileHandle;
use File::ReadBackwards;
use Fcntl ':seek';
use File::Spec::Functions 'catfile';
# also uses
# Carp;
# Time::HiRes 'time';

use enum qw( CON_DISCONNECTED CON_CONNECTING CON_CONNECTED );
use enum qw( SEND_DISABLE SEND_PIPE SEND_RCON SEND_SCREEN );
use enum qw( DEM_KICK DEM_BAN DEM_MUTE DEM_DENYBUILD );

# config: best to leave these defaults alone and set each var you want to override from default in config.cfg
#         e.g. if you want to change $logpath, put a line that says
#              $logpath = "/somewherelse/games.log";
#              in config.cfg

# Path to games.log
our $logpath = "games.log";

# Path to admin.dat
our $adminpath = "admin.dat";

# Where do we store the database
our $dbfile = "bot.db";

# Are we reading from the whole logfile to populate the db? Generally this is 0
our $backlog = 0;

# How should we send output responses back to the server?
#  SEND_DISABLE: Do not send output responses back to the server.
#  SEND_PIPE:    Write to a pipefile, as configured by the com_pipefile option. Best option if available.
#                Fast and robust.
#  SEND_RCON:    Use rcon
#                The only option that can get a response back from commands, but we don't use that anyway.
#                Slow and shows up in log files as rcon usage.
#  SEND_SCREEN:  Send a command to the screen session tremded is running in.
#                Very annoying if humans also attach to and use screen.
our $sendMethod = SEND_PIPE;

# rcon password, only used for SEND_RCON
our $rcpass = "myrconpassword";

# server ip, only used for SEND_RCON
our $ip = "127.0.0.1";

# server port, only used for SEND_RCON
our $port = "30720";

#  path to communication pipe to write to, only used for SEND_PIPE
our $pipefilePath = ".tremded_pipe";

# path to screen binary, only used for SEND_SCREEN
# leave default in most cases
our $screenPath = "screen";

# name of screen session, only used for SEND_SCREEN
# if your server startup script looks something like 'screen -S tremded ..."
# then 'tremded' is what you put here: i.e. whatever is after the -S
our $screenName = "tremded";

# name of screen window, only used for SEND_SCREEN
# the default '0' sends to whatever is in the first window in that screen
# session
our $screenWindow = "0";

do 'config.cfg';
# ------------ CONFIG STUFF ENDS HERE. DON'T MODIFY AFTER THIS OR ELSE!! ----------------


$SIG{INT} = \&cleanup;
$SIG{__DIE__} = \&errorHandler;

print( "TremAdminBot: A bot that provides some helper functions for Tremulous server administration\n" );
print( "TremAdminBot Copyright (C) 2011 Christopher Schwarz (lakitu7\@mercenariesguild.net)\n" );
print( "This program comes with ABSOLUTELY NO WARRANTY.\n" );
print( "This is free software, and you are welcome to redistribute it under certain conditions.\n" );
print( "For details, see gpl.txt\n" );
print( "-------------------------------------------------------------------------------------------\n" );

my $db = DBI->connect( "dbi:SQLite:${dbfile}", "", "", { RaiseError => 1, AutoCommit => 0 } ) or die( "Database error: " . $DBI::errstr );

# uncomment to dump all db activity to stdout
#`$db->{TraceLevel} = 1;

# create tables if they do not exist already
{
  my @tables;

  @tables = $db->tables( undef, undef, "users", undef );
  if( !scalar @tables )
  {
    $db->do( "CREATE TABLE users( userID INTEGER PRIMARY KEY, name TEXT, GUID TEXT, useCount INTEGER, seenTime DATETIME, IP TEXT, adminLevel INTEGER, city TEXT, region TEXT, country TEXT )" );
    $db->do( "CREATE INDEX guidIndex on users( GUID )" );
    $db->do( "INSERT INTO users ( name, GUID, useCount, adminLevel ) VALUES ( \'console\', \'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX\', 0, 999 )" );
  }

  @tables = $db->tables( undef, undef, "names", undef );
  if( !scalar @tables )
  {
    $db->do( "CREATE TABLE names( nameID INTEGER PRIMARY KEY, name TEXT, nameColored TEXT, userID INTEGER, useCount INTEGER, seenTime DATETIME, FOREIGN KEY( userID ) REFERENCES users( userID ) )" );
    $db->do( "CREATE INDEX nameIndex on names( name )" );
    $db->do( "INSERT INTO names ( name, nameColored, userID, useCount ) VALUES ( \'console\', \'console\', 1, 0 )" );
  }

  @tables = $db->tables( undef, undef, "memos", undef );
  if( !scalar @tables )
  {
    $db->do( "CREATE TABLE memos( memoID INTEGER PRIMARY KEY, userID INTEGER, sentBy INTEGER, sentTime DATETIME, readTime DATETIME, msg TEXT, FOREIGN KEY( userID ) REFERENCES users( userID ), FOREIGN KEY( sentby ) REFERENCES users( userID ) )" ) if( !scalar @tables );
  }

  @tables = $db->tables( undef, undef, "demerits", undef );
  if( !scalar @tables )
  {
    $db->do( "CREATE TABLE demerits( demeritID INTEGER PRIMARY KEY, userID INTEGER, demeritType INTEGER, admin INTEGER, reason TEXT, timeStamp DATETIME, duration INTEGER, IP TEXT, FOREIGN KEY( userID ) REFERENCES users( userID ), FOREIGN KEY( admin ) REFERENCES users( userID ) )" ) if( !scalar @tables );
  }
}

# allocate
use constant MAX_CLIENTS => 64;
our @connectedUsers;
our @admins;
for( my $i = 0; $i < MAX_CLIENTS; $i++ )
{
  push( @connectedUsers, { 'connected' => CON_DISCONNECTED } );
}
# console gets the last slot so -1 works
$connectedUsers[ MAX_CLIENTS ] =
{
  'connected' => CON_DISCONNECTED,
  'name' => 'console',
  'nameColored' => 'console',
  'aname' => 'console',
  'alevel' => 99,
  'GUID' => 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX',
  'IP' => '127.0.0.1',
  'userID' => 1,
  'slot' => -1
};
my $linesProcessed = -1;

my $servertsstr = "";
my $servertsminoff;
my $servertssecoff;

our $lineRegExp = qr/^([\d ]{3}):([\d]{2}) ([\w]+): ?(.*)/;
our $clientConnectRegExp = qr/^([\d]+) \[(.*)\] \(([\w]+)\) \"(.*)\" \"(.*)\"/;
our $clientDisconnectRegExp = qr/^([\d]+)/;
our $clientBeginRegExp = qr/^([\d-]+)/;
our $adminAuthRegExp = qr/^([\d-]+) \"(.+)\" \"(.+)\" \[([\d]+)\] \(([\w]+)\):/;
our $clientRenameRegExp = qr/^([\d]+) \[(.*)\] \(([\w]+)\) \"(.*)\" -> \"(.*)\" \"(.*)\"/;
our $sayRegExp = qr/^([\d-]+) \"(.+)\": (.*)/;
our $adminExecRegExp = qr/^([\w]+): ([\d-]+) \"(.*)\" \"(.*)\" \[([\d]+)\] \(([\w]*)\): ([\w]+):?/;
our $nameRegExpUnquoted= qr/.+/;
our $nameRegExpQuoted = qr/\".+\"/;
our $nameRegExp = qr/${nameRegExpQuoted}|${nameRegExpUnquoted}/o;

my $startupBacklog = 0;

my $addr;
my @send;
$send[ SEND_DISABLE ] = sub{};
$send[ SEND_PIPE ] = sub
{
  print( SENDPIPE "$_[ 0 ]\n" );
};
$send[ SEND_RCON ] = sub
{
  send( RCON, "\xff\xff\xff\xffrcon $rcpass $_[ 0 ]", 0, $addr );
};
$send[ SEND_SCREEN ] = sub
{
  my @cmd = ( $screenPath );
  push( @cmd, '-S', $screenName ) if( $screenName ne '' );
  push( @cmd, '-p', $screenWindow ) if( $screenWindow ne '' );
  push( @cmd, qw/-q -X stuff/, "\b" x 30 . $_[ 0 ] . "\n" );
  warn( "screen returned $?\n" ) if( system( @cmd ) != 0 );
};
my $sendq;

my %cmds;
sub loadcmds
{
  my( $sub, $cmd );
  %cmds = ();
  return unless( opendir( CMD, 'cmds' ) );
  print "Loading admin command handlers...\n";
  foreach( readdir( CMD ) )
  {
    next unless( /^(.+)\.pl$/i );
    $cmd = lc( $1 );
    $sub = do( catfile( 'cmds', $_ ) );
    unless( $sub )
    {
      warn( "$cmd: ", $@ || $!, "\n" );
      next;
    }
    $cmds{ $cmd } = $sub;
    print " Loaded: ${cmd}\n";
  }
  closedir( CMD );
  print "done\n";
}
loadcmds;

# this makes it much easier to send signals
$0 = __FILE__;

# these are generally usable like clients
sub loadadmins
{
  unless( open( ADMIN, '<', $adminpath ) )
  {
    warn( "could not open $adminpath: $!\n" );
    return;
  }

  for( my $i = 0; $i < MAX_CLIENTS; $i++ )
  {
    $connectedUsers[ $i ]{ 'aname' } = '';
    $connectedUsers[ $i ]{ 'alevel' } = 0;
  }

  @admins = ();
  while( my $line = <ADMIN> )
  {
    next unless( $line =~ /^\[admin]$/ );
    my $admin = {};
    while( $line = <ADMIN> )
    {
      last unless( my ( $key, $val ) = $line =~ /\s*(\w+)\s+=\s+((?<=")[^"]*(?="?)|[^\n]+)/ );
      $admin->{ lc( $key ) } = $val;
    }
    if( exists( $admin->{ 'level' } ) && exists( $admin->{ 'name' } ) )
    {
      push( @admins, {
        'connected' => CON_DISCONNECTED,
        'name' => $admin->{ 'name' },
        'nameColored' => $admin->{ 'name' },
        'aname' => $admin->{ 'name' },
        'alevel' => $admin->{ 'level' },
        'GUID' => $admin->{ 'guid' }
      });
      $admins[ -1 ]->{ 'name' } =~ s/\^[\da-z]//gi; #decolor

      # Copy info to @connectedUsers if user is connected
      my $target = getuser( $admin->{ 'guid' } );
      if( $target )
      {
        $target->{ 'alevel' } = $admin->{ 'level' };
        $target->{ 'aname' } = $admin->{ 'name' };
      }
    }
    redo if( $line ne '' ); #necessary if input is malformed in some way by manual editing
  }
  close( ADMIN );

  @admins = sort { $b->{ 'alevel' } <=> $a->{ 'alevel' } } @admins;
  for( my $i = 0; $i < @admins; $i++ )
  {
    $admins[ $i ]{ 'slot' } = MAX_CLIENTS + $i;
  }
}

my $inode;
sub openLog
{
  my $tries = $_[ 0 ] || 1;
  while( $tries-- > 0 )
  {
    last if( open( FILE, "<", $logpath ) );
    sleep( 1 ) if( $tries );
  }
  die( "open logfile failed: ${logpath}" ) unless( defined( fileno( FILE ) ) );

  if( !$backlog )
  {
    $inode = (stat( FILE ))[ 1 ];

    # Seek back to the start of the current game
    my $bw = File::ReadBackwards->new( $logpath );
    my $seekPos = 0;
    $startupBacklog = 1;

    while( defined( my $line = $bw->readline( ) ) )
    {
      if( $line =~ $lineRegExp )
      {
        my $arg0 = $3;
        if( $arg0 eq "InitGame" )
        {
          $seekPos = $bw->tell( );
          last( );
        }
      }
    }

    if( $seekPos )
    {
      seek( FILE, $seekPos, SEEK_SET ) or die( "seek fail" );
    }
    else
    {
      seek( FILE, 0, SEEK_END ) or die( "seek fail" );
    }
  }
}

if( !$backlog )
{
  $sendq = CommandQueue->new(
    'method' => $send[ $sendMethod ],
    'bucketrate' => $sendMethod == SEND_RCON ? 1000 : 1
  );

  $SIG{ 'HUP' } = sub
  {
    do( 'config.cfg' );
    $sendq->set( 'method', $send[ $sendMethod ] );
    $sendq->set( 'bucketrate', $sendMethod == SEND_RCON ? 1000 : 1 );
    loadcmds;
  };

  if( $sendMethod == SEND_PIPE )
  {
    die( "${pipefilePath} does not exist or is not a pipe. Is tremded running?" )
      if( !-p( $pipefilePath ) );
    open( SENDPIPE, ">", $pipefilePath );
    SENDPIPE->autoflush( 1 );
  }
  elsif( $sendMethod == SEND_RCON )
  {
    my $proto = getprotobyname( 'udp' );
    foreach my $af( AF_INET6, AF_INET )
    {
      if( $addr = gethostbyname2( $ip, $af ) )
      {
        print "Server rcon ip $ip resolved as " . inet_ntop( $af, $addr ), "\n";
        $addr = ( $af eq AF_INET6 ) ?
          pack_sockaddr_in6( $port, $addr ) :
          pack_sockaddr_in( $port, $addr );
        socket( RCON, $af, SOCK_DGRAM, $proto );
        last;
      }
    }
    die( "Can't resolve $ip\n" ) unless( $addr );
  }
}
else
{
  print( "Processing backlog on file ${logpath}. This will take a long time for large files.\n" );
}

my $ingame;
openLog;
while( 1 )
{
  $sendq->send unless( $backlog );
  if( my $line = <FILE> )
  {
    chomp $line;
    #`print "${line}\n";

    my $timestamp = timestamp( );

    $linesProcessed++;

    # Committing periodically instead of using autocommit speeds the db up massively
    if( $linesProcessed % 100 )
    {
      $db->commit( );
    }

    if( $backlog && $linesProcessed % 1000 )
    {
      print( "Processed ${linesProcessed} lines. Current timestamp: ${timestamp}\r" );
    }

    if( ( $servertsminoff, $servertssecoff, my $arg0, my $args ) = $line =~ $lineRegExp )
    {
      if( $arg0 eq "ShutdownGame" )
      {
        $ingame = 0;
      }
      elsif( $arg0 eq "InitGame" )
      {
        $ingame = 1;
        # this is only necessary in "live" mode since "readconfig" is sent when
        # the backlog is cleared
        loadadmins unless( $backlog || $startupBacklog );
      }
      elsif( $arg0 eq "ClientConnect" )
      {
        unless( @_ = $args =~ $clientConnectRegExp )
        {
          print( "Parse failure on ${arg0} ${args}\n" );
          next;
        }
        my( $slot, $ip, $guid, $name, $nameColored ) = @_;

        $connectedUsers[ $slot ]{ 'connected' } = CON_CONNECTING;
        $connectedUsers[ $slot ]{ 'name' } = $name;
        $connectedUsers[ $slot ]{ 'nameColored' } = $nameColored;
        $connectedUsers[ $slot ]{ 'IP' } = $ip;
        $connectedUsers[ $slot ]{ 'GUID' } = $guid;
        $connectedUsers[ $slot ]{ 'aname' } = "";
        $connectedUsers[ $slot ]{ 'alevel' } = "";
        $connectedUsers[ $slot ]{ 'slot' } = $slot;

        $connectedUsers[ $slot ]{ 'IP' } ||= "127.0.0.1";

        updateUsers( $timestamp, $slot );

      }
      elsif( $arg0 eq "ClientDisconnect" )
      {
        unless( $args =~ $clientDisconnectRegExp )
        {
          print( "Parse failure on ${arg0} ${args}\n" );
          next;
        }
        my $slot = $1;
        $connectedUsers[ $slot ]{ 'connected' } = CON_DISCONNECTED;
      }
      elsif( $arg0 eq "ClientBegin" )
      {
        unless( $args =~ $clientBeginRegExp )
        {
          print( "Parse failure on ${arg0} ${args}\n" );
          next;
        }
        my $slot = $1;
        my $name = $connectedUsers[ $slot ]{ 'name' };
        $connectedUsers[ $slot ]{ 'connected' } = CON_CONNECTED;

        $connectedUsers[ $slot ]{ 'alevel' } ||= 0;

        next if( $startupBacklog );

        memocheck( $slot, $timestamp );

      }
      elsif( $arg0 eq "AdminAuth" )
      {
        unless( @_ = $args =~ $adminAuthRegExp )
        {
          print( "Parse failure on ${arg0} ${args}\n" );
          next;
        }
        my( $slot, $name, $aname, $alevel, $guid ) = @_;

        $connectedUsers[ $slot ]{ 'aname' } = $aname;
        $connectedUsers[ $slot ]{ 'alevel' } = $alevel;
        $connectedUsers[ $slot ]{ 'GUID' } = $guid;
        my $userID = $connectedUsers[ $slot ]{ 'userID' };

        my $anameq = $db->quote( $aname );

        $db->do( "UPDATE users SET name=${anameq}, adminLevel=$alevel WHERE userID=${userID}" );
      }
      elsif( $arg0 eq "ClientRename" )
      {
        unless( @_ = $args =~ $clientRenameRegExp )
        {
          print( "Parse failure on ${arg0} ${args}\n" );
          next;
        }
        my( $slot, $ip, $guid, $previousName, $name, $nameColored ) = @_;
        $connectedUsers[ $slot ]{ 'previousName' } = $previousName;
        $connectedUsers[ $slot ]{ 'name' } = $name;
        $connectedUsers[ $slot ]{ 'nameColored' } = $nameColored;

        updateNames( $timestamp, $slot );
      }
      elsif( $arg0 eq "RealTime" )
      {
        $servertsstr = $args;
      }
      elsif( $arg0 eq "AdminExec" )
      {
        unless( @_ = $args =~ $adminExecRegExp )
        {
          print( "Parse failure on ${arg0} ${args}\n" );
          next;
        }
        my( $status, $slot, $name, $aname, $alevel, $guid, $acmd ) = @_;
        my @toks = quotewords( '\s+', 1, $args );
        @toks = grep( defined $_, @toks);
        my $acmdargs = "";
        $acmdargs = join( " ", @toks[ 7 .. $#toks ] ) if( scalar @toks >= 7 );

        my $nameq = $db->quote( $name );
        $acmd = lc( $acmd );

        my $userID = $connectedUsers[ $slot ]{ 'userID' };

        #`print "admin command: status: ${status} slot ${slot} name ${name} aname ${aname} acmd ${acmd} acmdargs ${acmdargs}\n";
        next if( "${status}" ne "ok" );

        # Commands after this point are not interacted with in startupBacklog conditions
        next if( $startupBacklog );

        next if( $backlog && exists( $cmds{ $acmd } ) );

        if( exists( $cmds{ $acmd } ) )
        {
          $cmds{ $acmd }( $connectedUsers[ $slot ], $acmdargs, $timestamp, $db );
        }
        elsif( $acmd eq "readconfig" )
        {
          loadadmins unless( $backlog );
        }
        elsif( $acmd eq "setlevel" )
        {
          next if( $backlog );

          unless( @_ = $acmdargs =~ /^(-?\d+) \((\w+)\) ($nameRegExpQuoted)/ )
          {
            print( "Parse failure on AdminExec ${acmdargs}\n" );
            next;
          }
          my( $level, $guid, $name ) = @_;
          # remove the "s
          $name = substr( $name, 1, length( $name ) - 2 );
          my $admin = getadmin( $guid );
          if( $admin )
          {
            $admin->{ 'alevel' } = $level;
            $admin->{ 'name' } = $name;
            $admin->{ 'aname' } = $name;
          }
          else
          {
            my $target = getuser( $guid );
            unless( $target )
            {
              print "setlevel with invalid target (this should never happen)\n" if( !$startupBacklog );
              next;
            }
            $admin = {
              'connected' => CON_DISCONNECTED,
              'name' => $name,
              'nameColored' => $target->{ 'nameColored' },
              'aname' => $name,
              'alevel' => $level,
              'GUID' => $guid,
              'slot' => MAX_CLIENTS + @admins
            };
            $target->{ 'alevel' } = $level;
            $target->{ 'aname' } = $name;
            push( @admins, $admin );
          }
        }
        elsif( $acmd eq "kick" )
        {
          unless( @_ = $acmdargs =~ /^([\d]+) \(([\w]+)\) ($nameRegExpQuoted): \"(.*)\"/ )
          {
            print( "Parse failure on AdminExec ${acmdargs}\n" );
            next;
          }
          my( $targslot, $targGUID, $targName, $reason ) = @_;
          my $targUserID = $connectedUsers[ $targslot ]{ 'userID' };
          my $targIPq = $db->quote( $connectedUsers[ $targslot ]{ 'IP' } );
          my $reasonq = $db->quote( $reason );
          $db->do( "INSERT INTO demerits (userID, demeritType, admin, timeStamp, ip, reason) VALUES ( ${targUserID}, " . DEM_KICK . ", ${userID}, ${timestamp}, ${targIPq}, ${reasonq} )" );
        }
        elsif( $acmd eq "ban" )
        {
          unless( @_ = $acmdargs =~ /^([\d]+) \(([\w]+)\) ($nameRegExpQuoted): \"(.*)\": \[(.*)\]/ )
          {
            print( "Parse failure on AdminExec ${acmdargs}\n" );
            next;
          }
          my( $duration, $targGUID, $targName, $reason, $targIP ) = @_;

          my $targUserID = userIDFromGUID( $targGUID );
          if( $targUserID == -1 )
          {
            print( "Error: ban on unknown guid ${targGUID}\n" );
            next;
          }

          my $targIPq = $db->quote( $targIP );
          my $reasonq = $db->quote( $reason );
          $db->do( "INSERT INTO demerits (userID, demeritType, admin, timeStamp, ip, reason, duration) VALUES ( ${targUserID}, " . DEM_BAN . ", ${userID}, ${timestamp}, ${targIPq}, ${reasonq}, $duration )" );
        }
        elsif( $acmd eq "mute" )
        {
          unless( @_ = $acmdargs =~ /^([\d]+) \(([\w]+)\) ($nameRegExpQuoted)/ )
          {
            print( "Parse failure on AdminExec ${acmdargs}\n" );
            next;
          }
          my( $targslot, $targGUID, $targName ) = @_;
          my $targUserID = $connectedUsers[ $targslot ]{ 'userID' };
          my $targIPq = $db->quote( $connectedUsers[ $targslot ]{ 'IP' } );
          $db->do( "INSERT INTO demerits (userID, demeritType, admin, timeStamp, ip) VALUES ( ${targUserID}, " . DEM_MUTE . ", ${userID}, ${timestamp}, ${targIPq} )" );
        }
        elsif( $acmd eq "denybuild" )
        {
          unless( @_ = $acmdargs =~ /^([\d]+) \(([\w]+)\) ($nameRegExpQuoted)/ )
          {
            print( "Parse failure on AdminExec ${acmdargs}\n" );
            next;
          }
          my( $targslot, $targGUID, $targName ) = @_;
          my $targUserID = $connectedUsers[ $targslot ]{ 'userID' };
          my $targIPq = $db->quote( $connectedUsers[ $targslot ]{ 'IP' } );
          $db->do( "INSERT INTO demerits (userID, demeritType, admin, timeStamp, ip) VALUES ( ${targUserID}, " . DEM_DENYBUILD . ", ${userID}, ${timestamp}, ${targIPq} )" );
        }
      }
      # Unused at present but left here for if other people want to screw with it
      #`elsif( $arg0 eq "Say" || $arg0 eq "SayTeam" || $arg0 eq "AdminMsg" )
      #`{
        #`$args =~ $sayRegExp;
        #`my $slot = $1;
        #`my $player = $2;
        #`my $said = $3;
        #`if( $said =~ /hi console/i )
        #`{
          #`replyToPlayer( $slot, "Hi ${player}!" );
        #`}
      #`}
    }
  }
  else
  {
    if( $backlog )
    {
      print "\nEnd of backlog\n";
      exit;
    }

    if( $startupBacklog )
    {
      $startupBacklog = 0;

      # do a readconfig on startup to see that admins are sorted and up to date
      sendconsole( "readconfig" );

      print( "Finished startup routines. Watching logfile:\n" );
    }

    # the log might have been moved
    my $ni = (stat( $logpath ))[ 1 ];
    if( !$ingame && ( !-f( $logpath ) || (stat( _ ))[ 1 ] != $inode ) )
    {
      print( "Logfile moved, reopening\n" );
      # retry for up to 3 seconds before giving up
      openLog( 3 );
    }
    else
    {
      seek( FILE, 0, SEEK_CUR );
      select( undef, undef, undef, $sendq->get( 'period' ) );
    }
  }
}

sub replyToPlayer
{
  my( $userSlot, $string ) = @_;
  $string =~ tr/"//d;
  $userSlot = $userSlot->{ 'slot' } if( ref( $userSlot ) );

  if( $userSlot >= 0 )
  {
    sendconsole( "pr ${userSlot} \"${string}\"" );
  }
  else
  {
    sendconsole( "echo \"${string}\"" );
  }
}

sub printToPlayers
{
  my( $string ) = @_;
  $string =~ tr/"//d;
  sendconsole( "pr -1 \"${string}\"" );
}

sub sendconsole
{
  my( $string ) = @_;
  return if( $backlog || $startupBacklog );

  $string =~ tr/[\13\15]//d;

  if( $sendMethod < 0 || $sendMethod >= @send )
  {
    die "Invalid $sendMethod configured";
  }

  $sendq->enqueue( $string );
}

sub updateUsers
{
  my( $timestamp, $slot ) = @_;
  my $guid = $connectedUsers[ $slot ]{ 'GUID' };
  my $guidq = $db->quote( $guid );
  my $name = lc( $connectedUsers[ $slot ]{ 'name' } );
  my $nameq = $db->quote( $name );
  my $ip = $connectedUsers[ $slot ]{ 'IP' };
  my $ipq = $db->quote( $ip );

  my $usersq = $db->prepare( "SELECT userID, adminLevel FROM users WHERE GUID = ${guidq} LIMIT 1" );
  $usersq->execute;

  my $user;

  if( $user = $usersq->fetchrow_hashref( ) )
  { }
  else
  {
    my $city = '';
    my $region = '';
    my $country = '';
    my $gip;
    if( ( $gip = main->can( 'getrecord' ) ) && ( $gip = $gip->( $ip ) ) )
    {
      $city = $gip->city;
      $region = $gip->region;
      $country = $gip->country_name;
    }
    $city = $db->quote( $city );
    $region = $db->quote( $region );
    $country = $db->quote( $country );

    $db->do( "INSERT INTO users ( name, GUID, useCount, seenTime, IP, adminLevel, city, region, country ) VALUES ( ${nameq}, ${guidq}, 0, ${timestamp}, ${ipq}, 0, ${city}, ${region}, ${country} )" );
    $usersq->execute;
    $user = $usersq->fetchrow_hashref( );
  }

  my $userID = $user->{ 'userID' };
  my $adminLevel = $user->{ 'adminLevel' };
  $connectedUsers[ $slot ]{ 'userID' } = $userID;

  return if( $startupBacklog );

  updateNames( $timestamp, $slot );

  if( !$adminLevel )
  {
    my $namesq = $db->prepare( "SELECT name FROM names WHERE userID = $userID ORDER BY useCount DESC LIMIT 1" );
    $namesq->execute;
    if( my $maxname = $namesq->fetchrow_hashref( ) )
    {
      my $maxnameq = $db->quote( $maxname->{ 'name' } );
      $db->do( "UPDATE users SET name=${maxnameq}, useCount=useCount+1, seenTime=${timestamp}, ip=${ipq} WHERE userID=${userID}" );
    }
    else
    {
      $db->do( "UPDATE users SET name=${nameq}, useCount=useCount+1, seenTime=${timestamp}, ip=${ipq} WHERE userID=${userID}" );
    }
  }
  else
  {
    $db->do( "UPDATE users SET useCount=useCount+1, seenTime=${timestamp}, ip=${ipq} WHERE userID=${userID}" );
  }
}

sub updateNames
{
  my( $timestamp, $slot ) = @_;
  my $name = lc( $connectedUsers[ $slot ]{ 'name' } );
  my $nameq = $db->quote( $name );
  my $namec = $connectedUsers[ $slot ]{ 'nameColored' };
  my $namecq = $db->quote( $namec );
  my $userID = $connectedUsers[ $slot ]{ 'userID' };
  my $nameID = "-1";

  my $namesq = $db->prepare( "SELECT nameID FROM names WHERE name = ${nameq} LIMIT 1" );
  $namesq->execute;

  my $namesref;

  if( my $ref = $namesq->fetchrow_hashref( ) )
  {
    $nameID = $ref->{nameID};
  }
  else
  {
    $db->do( "INSERT INTO names ( name, nameColored, userID, useCount, seenTime ) VALUES ( ${nameq}, ${namecq}, ${userID}, 0, ${timestamp} )" );
    $nameID = $db->last_insert_id( undef, undef, "names", "nameID" );
  }

  return if( $startupBacklog );
  $nameID ||= "-1";

  $db->do( "UPDATE names SET usecount=useCount+1, seenTime=${timestamp}, userID=${userID} WHERE nameID = ${nameID}" );
}

sub memocheck
{
  my( $slot, $timestamp ) = @_;
  my $name = $connectedUsers[ $slot ]{ 'name' };
  my $userID = $connectedUsers[ $slot ]{ 'userID' };

  my $q = $db->prepare( "SELECT COUNT(1) FROM memos WHERE memos.userID = ${userID} AND memos.readTime IS NULL" );
  $q->execute;

  my $ref = $q->fetchrow_hashref( );
  my $count = $ref->{ 'COUNT(1)' };

  replyToPlayer( $connectedUsers[ $slot ], "You have ${count} new memos. Use /memo list to read." ) if( $count > 0 );

}

sub getadmin
{
  my $guid = lc( $_[ 0 ] );
  foreach my $admin ( @admins )
  {
    return $admin if( lc( $admin->{ 'GUID' } ) eq $guid );
  }
  return;
}

sub cleanstring
{
  ( my $str = lc( $_[ 0 ] ) ) =~ s/[^\da-z]//gi;
  return $str;
}

sub findadmin
{
  my( $string, $err ) = @_;

  if( $string =~ /^\d+$/ )
  {
    if( $string < MAX_CLIENTS )
    {
      return $connectedUsers[ $string ]
        if( $connectedUsers[ $string ]{ 'connected' } != CON_DISCONNECTED );
      $$err = "no player connected in slot $string";
    }

    return $admins[ $string - MAX_CLIENTS ]
      if( $string - MAX_CLIENTS < @admins );

    $$err = "$string not in range 1-" . ( $#admins + MAX_CLIENTS );
    return;
  }

  $string = cleanstring( $string );
  my( $cmp, $match );
  foreach my $user ( @admins, @connectedUsers )
  {
    $cmp = cleanstring( $user->{ 'name' } );
    # names should be unique, so return on exact match
    return $user if( $string eq $cmp );
    if( index( $cmp, $string ) > -1 )
    {
      if( $match )
      {
        $$err = "more than one match.  use the listplayers or listadmins to " .
          "find an appropriate number to use instead of name.";
        return;
      }
      $match = $user;
    }
  }
  $$err = "no match.  use listplayers or listadmins to " .
    "find an appropriate number to use instead of name." unless( $match );
  return $match;
}

sub getuser
{
  my ( $string ) = @_;
  my $guid = lc( $string );
  foreach my $user ( @connectedUsers )
  {
    return $user if( lc( $user->{ 'GUID' } ) eq $guid );
  }
  return;
}

sub slotFromString
{
  my ( $string, $requireConnected, $err ) = @_;
  $string = lc( $string );

  if( $string =~ /^[\d]+/ )
  {
    if( $string >= MAX_CLIENTS )
    {
      $$err = "Invalid slot #${string}";
      return( -1 );
    }

    if( $requireConnected && $connectedUsers[ $string ]{ 'connected' } != CON_CONNECTED )
    {
      $$err = "Slot #${string} is not connected";
      return( -1 );
    }
    return $string;
  }

  my $exact = -1;
  my @matches;
  for( my $i = 0; $i < MAX_CLIENTS; $i++ )
  {
    my $uname = lc( $connectedUsers[ $i ]{ 'name' } );
    next if( !$uname );

    next if( $requireConnected && $connectedUsers[ $i ]{ 'connected' } != CON_CONNECTED );

    $exact = $i if( $uname eq $string );

    push( @matches, $i ) if( index( $uname, $string ) > -1 );
  }

  my $n = scalar @matches;
  if( $exact >= 0 )
  {
    return $exact;
  }
  elsif( $n == 1 )
  {
    return $matches[ 0 ];
  }
  elsif( $n > 0 )
  {
    $$err = "Multiple name matches. Be more specific or use a slot number";
    return( -1 );
  }
  else
  {
    $$err = "No current players match string: ${string}^7";
    return( -1 );
  }
}

sub userIDFromGUID
{
  my ( $guid ) = @_;
  my $guidq = $db->quote( $guid );
  my $usersq = $db->prepare( "SELECT userID FROM users WHERE GUID = ${guidq} LIMIT 1" );
  $usersq->execute;

  my $user;

  if( $user = $usersq->fetchrow_hashref( ) )
  {
    return $user->{'userID'};
  }
  else
  {
    return "-1";
  }
}

sub timestamp
{
  if( $backlog )
  {
    my $out = $servertsstr;
    $out =~ tr/\//-/;
    return( $db->quote( $out ) );
  }
  my $q = $db->prepare( "SELECT DATETIME('now','localtime')" );
  $q->execute;
  my $out = $q->fetchrow_array( );

  $out = $db->quote( $out );
  return $out;
}

sub errorHandler
{
  # don't croak because of an error in a command handler or failed eval
  die( @_ ) if( $^S || !defined( $^S ) );
  print "Error: $_[ 0 ]";
  cleanup( );
}

sub cleanup
{
  close( FILE );
  close( SENDPIPE ) if( $sendMethod == SEND_PIPE );
  $db->disconnect( ) or warn( "Disconnection failed: $DBI::errstr\n" );
  exit;
}


####
package CommandQueue;
use common::sense;
use Data::Dumper;
use Carp;
use Time::HiRes 'time';

sub new
{
  my( $package, %options ) = @_;
  return bless( {
    'time' => 0,
    'period' => 0.05,
    'queue' => [],
    'maxlength' => 1023,
    'sent' => 0,
    'count' => 0,
    'bucketmax' => 10,
    'bucketrate' => 1000,
    %options
  }, $package );
}

sub get
{
  my( $cq, $key ) = @_;
  return $cq->{ ${key} };
}

sub set
{
  my( $cq, $key, $value ) = @_;
  my $current = $cq->{ $key };
  $cq->{ $key } = $value if( @_ == 3 );
  return $current;
}

sub send
{
  my( $cq ) = @_;
  my $t = time;

  if( $t - $cq->{ 'time' } >= $cq->{ 'period' } )
  {
    $cq->{ 'sent' } = 0;
  }

  $cq->{ 'count' } -= int( ( $t * 1000 - $cq->{ 'time' } * 1000 ) /
    $cq->{ 'bucketrate' } );
  $cq->{ 'count' } = 0 if( $cq->{ 'count' } < 0 );

  my $remaining = $cq->{ 'maxlength' } - $cq->{ 'sent' };
  my( $command, $len );
  while( @{ $cq->{ 'queue' } } && $cq->{ 'count' } < $cq->{ 'bucketmax' } )
  {
    $len = length( $cq->{ 'queue' }[ 0 ] );
    last if( $len > $remaining );
    $command = shift( @{ $cq->{ 'queue' } } );
    print "Sent: $command\n";
    $remaining -= $len;
    $cq->{ 'sent' } += $len;
    $cq->{ 'method' }( $command );
    $cq->{ 'count' }++;
  }

  $cq->{ 'time' } = $t if( $command );
}

sub enqueue
{
  my( $cq, $command ) = @_;
  if( length( $command ) > $cq->{ 'maxlength' } )
  {
    Carp::carp( "Command too large (>$cq->{ 'maxlength' }): $command" );
  }
  else
  {
    push( @{ $cq->{ 'queue' } }, $command );
  }
  $cq->send;
}
