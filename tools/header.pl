#!/usr/bin/env perl

my %header = qw(
    int8_t stdint.h
    int16_t stdint.h
    int32_t stdint.h
    int64_t stdint.h

    uint8_t stdint.h
    uint16_t stdint.h
    uint32_t stdint.h
    uint64_t stdint.h

    size_t sys/types.h
    ssize_t sys/types.h

    sockaddr arpa/inet.h
    sockaddr_in arpa/inet.h
    AF_INET arpa/inet.h
    INADDR_ANY arpa/inet.h
);

# print "argv[0]: $ARGV[0]\n";
# print "argv[1]: $ARGV[1]\n";
# print "argv[2]: $ARGV[2]\n";
my $param = $ARGV[0];
if ($param =~ /^.+$/){
    print "#include <$header{$param}>\n";
}else{
    print "Usage: $0 <typename>";
    exit;
}

