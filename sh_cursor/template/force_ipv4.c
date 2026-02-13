/*
 * LD_PRELOAD shim for Sherlock compute nodes:
 *   1. Forces IPv4-only DNS resolution (no IPv6)
 *   2. Bypasses DNS sinkhole for blocked domains via CURSOR_DNS_OVERRIDES
 *
 * CURSOR_DNS_OVERRIDES format: "host1=ip1,host2=ip2,..."
 *
 * Build: gcc -shared -fPIC -o force_ipv4.so force_ipv4.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <netdb.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <stdlib.h>
#include <string.h>

/* Look up node in CURSOR_DNS_OVERRIDES; returns 1 and fills addr on match */
static int lookup_override(const char *node, struct in_addr *addr)
{
    const char *env = getenv("CURSOR_DNS_OVERRIDES");
    if (!env || !node)
        return 0;

    /* Work on a copy so we can tokenise */
    char *buf = strdup(env);
    if (!buf)
        return 0;

    int found = 0;
    char *saveptr;
    for (char *tok = strtok_r(buf, ",", &saveptr);
         tok;
         tok = strtok_r(NULL, ",", &saveptr))
    {
        char *eq = strchr(tok, '=');
        if (!eq)
            continue;
        *eq = '\0';
        const char *host = tok;
        const char *ip   = eq + 1;

        /* Exact match or wildcard suffix match (*.example.com) */
        if (strcmp(host, node) == 0) {
            found = (inet_pton(AF_INET, ip, addr) == 1);
            break;
        }
        if (host[0] == '*' && host[1] == '.') {
            const char *suffix = host + 1; /* .example.com */
            size_t slen = strlen(suffix);
            size_t nlen = strlen(node);
            if (nlen >= slen && strcmp(node + nlen - slen, suffix) == 0) {
                found = (inet_pton(AF_INET, ip, addr) == 1);
                break;
            }
        }
    }

    free(buf);
    return found;
}

int getaddrinfo(const char *node, const char *service,
                const struct addrinfo *hints, struct addrinfo **res)
{
    static int (*real_getaddrinfo)(const char *, const char *,
                                  const struct addrinfo *,
                                  struct addrinfo **) = NULL;
    if (!real_getaddrinfo)
        real_getaddrinfo = dlsym(RTLD_NEXT, "getaddrinfo");

    /* Check for DNS override */
    struct in_addr override_addr;
    if (node && lookup_override(node, &override_addr)) {
        /* Build a minimal addrinfo result for the overridden IP */
        struct addrinfo override_hints = {0};
        override_hints.ai_family   = AF_INET;
        override_hints.ai_socktype = hints ? hints->ai_socktype : SOCK_STREAM;
        override_hints.ai_protocol = hints ? hints->ai_protocol : 0;

        /* Use real getaddrinfo on the numeric IP string to build a proper result */
        char ip_str[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &override_addr, ip_str, sizeof(ip_str));
        override_hints.ai_flags = AI_NUMERICHOST;
        return real_getaddrinfo(ip_str, service, &override_hints, res);
    }

    /* Force AF_INET for all other lookups */
    struct addrinfo modified_hints;
    if (hints) {
        modified_hints = *hints;
    } else {
        modified_hints = (struct addrinfo){0};
    }
    modified_hints.ai_family = AF_INET;

    return real_getaddrinfo(node, service, &modified_hints, res);
}
