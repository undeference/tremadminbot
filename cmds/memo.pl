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

sub
{
  my( $user, $acmdargs, $timestamp, $db ) = @_;

  unless( $acmdargs =~ /^([\w]+)/ )
  {
    replyToPlayer( $user, "^3memo:^7 commands: list, read, send, outbox, unsend, clear" );
    return;
  }

  my $memocmd = lc( $1 );

  if( $memocmd eq "send" )
  {
    my @split = shellwords( $acmdargs );
    shift( @split );
    unless( scalar @split >= 2 )
    {
      replyToPlayer( $user, "^3memo:^7 usage: memo send <name> <message>" );
      return;
    }

    my $memoname = lc( shift( @split ) );
    my $memo = join( " ", @split );

    my @matches;
    my $lastmatch;
    my $exact = -1;

    # by userID
    if( $memoname =~ /^\d+$/ )
    {
      my $q = $db->prepare_cached( "SELECT userID, name FROM users WHERE userID=?" );
      $q->execute( $memoname );
      if( my $ref = $q->fetchrow_hashref )
      {
        $lastmatch = $memoname;
        push( @matches, $ref );
      }
      else
      {
        replyToPlayer( $user, "^3memo:^7 unknown userID $memoname" );
        return;
      }
    }
    else
    {
      $memoname =~ tr/\"//d;
      my $memonamelq = "%" . $memoname . "%";

      my $q = $db->prepare_cached( "SELECT userID, name, seenTime FROM users WHERE useCount > 10 AND name LIKE ? AND seenTime > datetime( ?, \'-3 months\' ) ORDER BY CASE WHEN name = ? then 999999 else useCount END DESC LIMIT 10" );
      $q->execute( $memonamelq, $timestamp, $memoname );

      my $i = 0;
      while( my $ref = $q->fetchrow_hashref( ) )
      {
        $exact = $i if( $ref->{ 'name' } eq $memoname );
        $lastmatch = $ref->{ 'userID' };
        push( @matches, $ref );
        last if( $exact >= 0 );
        $i++;
      }
    }

    if( $exact >= 0 || @matches == 1 )
    {
      $exact ||= 0; # warning
      my $st = $db->prepare_cached( "INSERT INTO memos (userID, sentBy, sentTime, msg) VALUES (?, ?, ?, ?)" );
      $st->execute( $matches[ $exact ]{ 'userID' }, $user->{userID}, $timestamp, $memo );
      replyToPlayer( $user, "^3memo:^7 memo left for $matches[ $exact ]{ 'name' }" );
    }
    elsif( scalar @matches > 1 )
    {
      replyToPlayer( $user, "^3memo:^7 multiple matches. Be more specific or use userID: " );
      foreach( @matches )
      {
        replyToPlayer( $user, "^3  $_->{ 'userID' }  $_->{ 'seenTime' } ^7$_->{ 'name' }" );
      }
    }
    else
    {
      replyToPlayer( $user, "^3memo:^7 invalid memo target: ${memoname} not seen in last 3 months or at least 10 times." );
    }
  }
  elsif( $memocmd eq "list" )
  {
    my $q = $db->prepare_cached( "SELECT memos.memoID, memos.readTime, users.name FROM memos JOIN users ON users.userID = memos.sentBy WHERE memos.userID = ? ORDER BY memoID ASC" );
    $q->execute( $user->{userID} );

    my @memos;
    my @readMemos;
    while( my $ref = $q->fetchrow_hashref( ) )
    {
      my $name = $ref->{ 'name' };
      my $readTime = $ref->{ 'readTime' };
      my $memoID = $ref->{ 'memoID' };

      if( $readTime )
      {
        push( @readMemos, ${memoID} );
      }
      else
      {
        push( @memos, ${memoID} );
      }
    }
    my $newCount = scalar @memos;
    my $readCount = scalar @readMemos;
    replyToPlayer( $user, "^3memo:^7 You have ${newCount} new Memos: " . join( "^3,^7 ", @memos ) . ". Use /memo read <memoID>" ) if( $newCount );
    replyToPlayer( $user, "^3memo:^7 You have ${readCount} read Memos: " . join( "^3,^7 ", @readMemos ) ) if( $readCount );
    replyToPlayer( $user, "^3memo:^7 You have no memos." ) if( !$newCount && !$readCount );
  }

  elsif( $memocmd eq "read" )
  {
    my $memoID;
    unless( ( $memoID ) = $acmdargs =~ /^(?:[\w]+) ([\d]+)/ )
    {
      replyToPlayer( $user, "^3memo:^7 usage: memo read <memoID>" );
      return;
    }

    my $q = $db->prepare_cached( "SELECT memos.memoID, memos.sentTime, memos.msg, users.name FROM memos JOIN users ON users.userID = memos.sentBy WHERE memos.memoID = ? AND memos.userID = ?" );
    $q->execute( $memoID, $user->{userID} );
    if( my $ref = $q->fetchrow_hashref( ) )
    {
      my $id = $ref->{ 'memoID' };
      my $from = $ref->{ 'name' };
      my $sentTime = $ref->{ 'sentTime' };
      my $msg = $ref->{ 'msg' };

      replyToPlayer( $user, "Memo: ${id} From: ${from} Sent: ${sentTime}" );
      replyToPlayer( $user, " Msg: ${msg}" );

      my $st = $db->prepare_cached( "UPDATE memos SET readTime=? WHERE memoID=?" );
      $st->execute( $timestamp, $memoID );
    }
    else
    {
      replyToPlayer( $user, "^3memo:^7: Invalid memoID: ${memoID}" );
    }
  }
  elsif( $memocmd eq "outbox" )
  {
    my $q = $db->prepare_cached( "SELECT memos.memoID, users.name FROM memos JOIN users ON users.userID = memos.userID WHERE memos.sentBy = ? AND memos.readTime IS NULL ORDER BY memoID ASC" );
    $q->execute( $user->{userID} );

    my @memos;
    while( my $ref = $q->fetchrow_hashref( ) )
    {
      my $name = $ref->{ 'name' };
      my $memoID = $ref->{ 'memoID' };

      push( @memos, "ID: ${memoID} To: ${name}" );
    }
    replyToPlayer( $user, "^3memo:^7 Unread Sent Memos: " . join( "^3,^7 ", @memos ) ) if( scalar @memos );
    replyToPlayer( $user, "^3memo:^7 You have no unread sent memos." ) if( ! scalar @memos );
  }
  elsif( $memocmd eq "unsend" )
  {
    my $memoID;
    unless( ( $memoID ) = $acmdargs =~ /^(?:[\w]+) ([\d]+)/ )
    {
      replyToPlayer( $user, "^3memo:^7 usage: memo unsend <memoID>" );
      return;
    }

    my $st = $db->prepare_cached( "DELETE FROM memos WHERE sentBy = ? AND memoID = ?" );
    my $count = $db->execute( $user->{userID}, $memoID );
    if( $count ne "0E0" )
    {
      replyToPlayer( $user, "^3memo:^7 deleted sent memo ${memoID}" );
    }
    else
    {
      replyToPlayer( $user, "^3memo:^7 invalid memoID ${memoID}" );
    }
  }
  elsif( $memocmd eq "clear" )
  {
    my $clearcmd;
    unless( ( $clearcmd ) = $acmdargs =~ /^(?:[\w]+) ([\w]+)/ )
    {
      replyToPlayer( $user, "^3memo:^7 usage: memo clear <ALL|READ>" );
      return;
    }
    $clearcmd = lc( $clearcmd );

    if( $clearcmd eq "all" )
    {
      my $st = $db->prepare_cached( "DELETE FROM memos WHERE userID = ?" );
      my $count = $db->execute( $user->{userID} );
      $count = 0 if( $count eq "0E0" );
      replyToPlayer( $user, "^3memo:^7 cleared ${count} memos" );
    }
    elsif( $clearcmd eq "read" )
    {
      my $st = $db->prepare_cached( "DELETE FROM memos WHERE userID = ? AND readTime IS NOT NULL" );
      my $count = $st->execute( $user->{userID} );
      $count = 0 if( $count eq "0E0" );
      replyToPlayer( $user, "^3memo:^7 cleared ${count} read memos" );
    }
    else
    {
      replyToPlayer( $user, "^3memo:^7 usage: memo clear <ALL|READ>" );
    }
  }
  else
  {
    replyToPlayer( $user, "^3memo:^7 commands: list, read, send, outbox, unsend, clear" );
  }
};
