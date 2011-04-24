use common::sense;
our @connectedUsers;

sub
{
  my( $user, $acmdargs, $timestamp, $db ) = @_;

  print( "Cmd: $user->{name} /l1 ${acmdargs}\n" );

  if( $acmdargs eq "" )
  {
    replyToPlayer( $user, "^3l1:^7 usage: l1 <name|slot#>" );
    next;
  }

  my $err = "";
  my $targslot = slotFromString( $acmdargs, 1, \$err );
  if( $targslot < 0 )
  {
    replyToPlayer( $user, "^3l1:^7 ${err}" );
    next;
  }

  if( $connectedUsers[ $targslot ]{ 'alevel' } == 0 )
  {
    printToPlayers( "^3l1:^7 $user->{name} set ${connectedUsers[ $targslot ]{ 'name' }} to level 1" );
    sendconsole( "setlevel ${targslot} 1" );
  }
  else
  {
    replyToPlayer( $user, "^3l1:^7 User #${targslot} is not level 0" );
    next;
  }
};