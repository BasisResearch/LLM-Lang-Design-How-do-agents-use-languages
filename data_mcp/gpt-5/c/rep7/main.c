#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#include <ctype.h>

#define MAX_USERNAME_LEN 50
#define MIN_USERNAME_LEN 3
#define MIN_PASSWORD_LEN 8

#define TOKEN_LEN 64
#define MAX_REQ_SIZE (1024*1024)
#define HEADER_BUF_SIZE (128*1024)

static volatile sig_atomic_t running = 1;

struct User {
    int id;
    char *username;
    char *password; // in-memory plain
};

struct Todo {
    int id;
    int user_id;
    char *title;
    char *description;
    int completed; // 0/1
    char created_at[21];
    char updated_at[21];
    int deleted; // 0/1
};

struct Session {
    char token[TOKEN_LEN+1];
    int user_id;
    int valid; // 1 valid, 0 invalidated
};

static struct User *users = NULL; static size_t users_count=0, users_cap=0; static int next_user_id=1;
static struct Todo **todos = NULL; static size_t todos_count=0, todos_cap=0; static int next_todo_id=1;
static struct Session *sessions=NULL; static size_t sessions_count=0, sessions_cap=0;
static pthread_mutex_t db_mutex = PTHREAD_MUTEX_INITIALIZER;

static void ensure_users_cap(){ if(users_count>=users_cap){ size_t nc=users_cap?users_cap*2:16; struct User*nu=realloc(users,nc*sizeof(*users)); if(!nu){perror("realloc users"); exit(1);} users=nu; users_cap=nc; } }
static void ensure_todos_cap(){ if(todos_count>=todos_cap){ size_t nc=todos_cap?todos_cap*2:32; struct Todo**nt=realloc(todos,nc*sizeof(*todos)); if(!nt){perror("realloc todos"); exit(1);} todos=nt; todos_cap=nc; } }
static void ensure_sessions_cap(){ if(sessions_count>=sessions_cap){ size_t nc=sessions_cap?sessions_cap*2:32; struct Session*ns=realloc(sessions,nc*sizeof(*sessions)); if(!ns){perror("realloc sessions"); exit(1);} sessions=ns; sessions_cap=nc; } }

static int timing_safe_strcmp(const char *a,const char*b){ size_t la=strlen(a), lb=strlen(b); size_t l=la>lb?la:lb; unsigned char r=0; for(size_t i=0;i<l;i++){ unsigned char ca=i<la?(unsigned char)a[i]:0; unsigned char cb=i<lb?(unsigned char)b[i]:0; r|=(unsigned char)(ca^cb);} return r; }

static int is_valid_username(const char *u){ size_t len=strlen(u); if(len<MIN_USERNAME_LEN||len>MAX_USERNAME_LEN) return 0; for(size_t i=0;i<len;i++){ if(!(isalnum((unsigned char)u[i])||u[i]=='_')) return 0; } return 1; }

static void iso8601_utc_now(char out[21]){
    time_t t=time(NULL); struct tm tm_utc; gmtime_r(&t,&tm_utc); strftime(out,21,"%Y-%m-%dT%H:%M:%SZ",&tm_utc);
}

static int generate_token(char out[TOKEN_LEN+1]){
    size_t raw_len=TOKEN_LEN/2; unsigned char buf[64]; if(raw_len>sizeof(buf)) return -1; int fd=open("/dev/urandom",O_RDONLY); if(fd<0) return -1; ssize_t rd=read(fd,buf,raw_len); close(fd); if(rd!=(ssize_t)raw_len) return -1; static const char*hex="0123456789abcdef"; for(size_t i=0;i<raw_len;i++){ out[2*i]=hex[(buf[i]>>4)&0xF]; out[2*i+1]=hex[buf[i]&0xF]; } out[TOKEN_LEN]='\0'; return 0;
}

static struct User* find_user_by_username(const char*username){ for(size_t i=0;i<users_count;i++){ if(users[i].username && strcmp(users[i].username,username)==0) return &users[i]; } return NULL; }
static struct User* find_user_by_id(int id){ for(size_t i=0;i<users_count;i++){ if(users[i].id==id) return &users[i]; } return NULL; }
static struct Todo* find_todo_by_id(int id){ for(size_t i=0;i<todos_count;i++){ struct Todo*t=todos[i]; if(t && !t->deleted && t->id==id) return t; } return NULL; }
static struct Session* find_session(const char*token){ for(size_t i=0;i<sessions_count;i++){ if(sessions[i].valid && strcmp(sessions[i].token,token)==0) return &sessions[i]; } return NULL; }

// Minimal JSON parser for our specific needs
// Supports: objects with string keys; values: string, boolean (true/false)

typedef struct { char *key; int is_string; char *sval; int is_bool; int bval; } JPair;

typedef struct { JPair *pairs; size_t count; size_t cap; } JObject;

static void jobj_free(JObject *o){ if(!o) return; for(size_t i=0;i<o->count;i++){ free(o->pairs[i].key); if(o->pairs[i].is_string) free(o->pairs[i].sval); } free(o->pairs); o->pairs=NULL; o->count=o->cap=0; }

static void skip_ws(const char* s, size_t len, size_t *i){ while(*i<len && (s[*i]==' '||s[*i]=='\n'||s[*i]=='\r'||s[*i]=='\t')) (*i)++; }

static int parse_string(const char* s, size_t len, size_t *i, char **out){ if(*i>=len||s[*i]!='"') return -1; (*i)++; char *buf=NULL; size_t cap=64, pos=0; buf=malloc(cap); if(!buf) return -1; while(*i<len){ char c=s[*i]; if(c=='"'){ (*i)++; break; } if(c=='\\'){ (*i)++; if(*i>=len){ free(buf); return -1; } char e=s[*i]; (*i)++; char outc=e; switch(e){ case '"': outc='"'; break; case '\\': outc='\\'; break; case 'n': outc='\n'; break; case 'r': outc='\r'; break; case 't': outc='\t'; break; default: outc=e; }
            if(pos+1>=cap){ cap*=2; char *nb=realloc(buf,cap); if(!nb){ free(buf); return -1;} buf=nb; }
            buf[pos++]=outc; continue; }
        (*i)++;
        if(pos+1>=cap){ cap*=2; char *nb=realloc(buf,cap); if(!nb){ free(buf); return -1;} buf=nb; }
        buf[pos++]=c;
    }
    if(pos+1>=cap){ char *nb=realloc(buf,pos+1); if(!nb){ free(buf); return -1;} buf=nb; }
    buf[pos]='\0'; *out=buf; return 0; }

static int jobj_add(JObject *o, JPair p){ if(o->count>=o->cap){ size_t nc=o->cap?o->cap*2:8; JPair*np=realloc(o->pairs, nc*sizeof(*np)); if(!np) return -1; o->pairs=np; o->cap=nc; } o->pairs[o->count++]=p; return 0; }

static int parse_json_object(const char* s, size_t len, JObject *out){ memset(out,0,sizeof(*out)); size_t i=0; skip_ws(s,len,&i); if(i>=len||s[i]!='{') return -1; i++; skip_ws(s,len,&i); if(i<len && s[i]=='}'){ i++; return 0; }
    while(i<len){ skip_ws(s,len,&i); char *k=NULL; if(parse_string(s,len,&i,&k)!=0) { jobj_free(out); return -1; }
        skip_ws(s,len,&i); if(i>=len||s[i] != ':'){ free(k); jobj_free(out); return -1; } i++; skip_ws(s,len,&i);
        JPair p; memset(&p,0,sizeof(p)); p.key=k;
        if(i<len && s[i]=='"'){
            char *v=NULL; if(parse_string(s,len,&i,&v)!=0){ free(k); jobj_free(out); return -1; } p.is_string=1; p.sval=v;
        } else if(i+4<=len && strncmp(s+i,"true",4)==0){ i+=4; p.is_bool=1; p.bval=1; }
        else if(i+5<=len && strncmp(s+i,"false",5)==0){ i+=5; p.is_bool=1; p.bval=0; }
        else { free(k); jobj_free(out); return -1; }
        if(jobj_add(out,p)!=0){ if(p.is_string) free(p.sval); free(p.key); jobj_free(out); return -1; }
        skip_ws(s,len,&i); if(i<len && s[i]==','){ i++; continue; }
        skip_ws(s,len,&i); if(i<len && s[i]=='}'){ i++; break; }
        else { jobj_free(out); return -1; }
    }
    return 0; }

static const char* jobj_get_string(JObject *o, const char *key){ for(size_t i=0;i<o->count;i++){ if(strcmp(o->pairs[i].key,key)==0 && o->pairs[i].is_string) return o->pairs[i].sval; } return NULL; }
static int jobj_get_bool(JObject *o, const char *key, int *found){ for(size_t i=0;i<o->count;i++){ if(strcmp(o->pairs[i].key,key)==0 && o->pairs[i].is_bool){ *found=1; return o->pairs[i].bval; } } *found=0; return 0; }
static int jobj_has_key(JObject *o, const char *key){ for(size_t i=0;i<o->count;i++){ if(strcmp(o->pairs[i].key,key)==0) return 1; } return 0; }

// HTTP helpers
static ssize_t write_all(int fd, const void *buf, size_t len){ const char *p=(const char*)buf; size_t off=0; while(off<len){ ssize_t w=write(fd,p+off,len-off); if(w<0){ if(errno==EINTR) continue; return -1;} off+=w; } return (ssize_t)off; }

static void send_json_response(int fd, int status, const char *body_fmt, ...) {
    char body[8192]; va_list ap; va_start(ap, body_fmt); vsnprintf(body, sizeof(body), body_fmt, ap); va_end(ap);
    char header[4096]; const char *status_text = (status==200?"OK": status==201?"Created": status==204?"No Content": status==400?"Bad Request": status==401?"Unauthorized": status==404?"Not Found": status==409?"Conflict":"Internal Server Error");
    int body_len = (int)strlen(body);
    int n = snprintf(header, sizeof(header),
        "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n",
        status, status_text, body_len);
    write_all(fd, header, n);
    write_all(fd, body, body_len);
}

static void send_no_content_response(int fd){
    char header[256]; int n=snprintf(header,sizeof(header),"HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"); write_all(fd, header, n);
}

static void set_cookie_and_send_json(int fd, int status, const char *set_cookie_hdr, const char *body_fmt, ...) {
    char body[8192]; va_list ap; va_start(ap, body_fmt); vsnprintf(body, sizeof(body), body_fmt, ap); va_end(ap);
    char header[4096]; const char *status_text = (status==200?"OK": status==201?"Created":"OK");
    int body_len = (int)strlen(body);
    int n = snprintf(header, sizeof(header),
        "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nSet-Cookie: %s\r\nConnection: close\r\n\r\n",
        status, status_text, body_len, set_cookie_hdr);
    write_all(fd, header, n);
    write_all(fd, body, body_len);
}

static void json_escape(const char *s, char *out, size_t outsz){ size_t o=0; for(size_t i=0; s && s[i] && o+2<outsz; i++){ unsigned char c=(unsigned char)s[i]; if(c=='"' || c=='\\'){ if(o+2<outsz){ out[o++]='\\'; out[o++]=c; } } else if(c=='\n'){ if(o+2<outsz){ out[o++]='\\'; out[o++]='n'; } } else if(c=='\r'){ if(o+2<outsz){ out[o++]='\\'; out[o++]='r'; } } else if(c=='\t'){ if(o+2<outsz){ out[o++]='\\'; out[o++]='t'; } } else if(c<0x20){ if(o+6<outsz){ o+=snprintf(out+o,outsz-o,"\\u%04x",c); } } else { out[o++]=c; } }
    if(o<outsz) out[o]='\0'; else out[outsz-1]='\0'; }

static void send_error_json(int fd, int status, const char *msg){ char esc[2048]; json_escape(msg, esc, sizeof(esc)); send_json_response(fd, status, "{\"error\":\"%s\"}", esc); }

// Cookie parsing
static int get_session_id_from_cookie(const char *cookie_hdr, char out[TOKEN_LEN+1]){
    if(!cookie_hdr) return 0; // not found
    size_t n=strlen(cookie_hdr);
    size_t i=0; while(i<n){
        while(i<n && (cookie_hdr[i]==' '||cookie_hdr[i]==';')) i++;
        size_t k=i; while(i<n && cookie_hdr[i] != '=' && cookie_hdr[i] != ';') i++;
        if(i>=n || cookie_hdr[i] != '='){
            while(i<n && cookie_hdr[i] != ';') i++;
            if(i<n && cookie_hdr[i]==';') i++;
            continue;
        }
        size_t keylen=i-k; i++; size_t v=i; while(i<n && cookie_hdr[i] != ';') i++; size_t vlen=i-v; if(i<n && cookie_hdr[i]==';') i++;
        if(keylen==10 && strncmp(cookie_hdr+k, "session_id", 10)==0){ size_t cpy = vlen < TOKEN_LEN ? vlen : TOKEN_LEN; memcpy(out, cookie_hdr+v, cpy); out[cpy]='\0'; return 1; }
    }
    return 0;
}

// Business logic helpers
static void delete_todo(struct Todo *t){ if(t) t->deleted=1; }

static void handle_connection(int client_fd, const char *client_ip){ (void)client_ip; char buf[HEADER_BUF_SIZE]; size_t used=0; ssize_t r;
    // Read headers until CRLFCRLF
    while(used < sizeof(buf)){
        r = read(client_fd, buf+used, sizeof(buf)-used);
        if(r<0){ if(errno==EINTR) continue; close(client_fd); return; }
        if(r==0){ break; }
        used += (size_t)r;
        if(used >= 4){ for(size_t i=3;i<used;i++){ if(buf[i-3]=='\r'&&buf[i-2]=='\n'&&buf[i-1]=='\r'&&buf[i]=='\n'){ goto headers_done; } } }
    }
headers_done: ;
    // Find end of headers (position after the CRLFCRLF)
    size_t hdr_end=0; for(size_t i=3;i<used;i++){ if(buf[i-3]=='\r'&&buf[i-2]=='\n'&&buf[i-1]=='\r'&&buf[i]=='\n'){ hdr_end = i+1; break; } }
    if(hdr_end==0){ // malformed
        send_error_json(client_fd, 400, "Bad Request"); close(client_fd); return; }
    // Parse request line
    char *reqline = strndup(buf, strcspn(buf, "\r\n")); if(!reqline){ close(client_fd); return; }
    char method[8]={0}, path[256]={0}, version[16]={0};
    sscanf(reqline, "%7s %255s %15s", method, path, version);
    free(reqline);
    // Parse headers for Content-Length, Cookie, Expect
    size_t content_length = 0; char cookie_hdr[1024]={0}; int expect_100 = 0;
    size_t pos = strcspn(buf, "\r\n"); pos += 2; // move past first CRLF
    while(pos < hdr_end){ size_t line_end = pos; while(line_end < hdr_end && !(buf[line_end]=='\r' && buf[line_end+1]=='\n')) line_end++; size_t line_len = line_end - pos; if(line_len==0) break; // empty line
        // Extract header name and value
        char *line = strndup(buf+pos, line_len); if(!line){ close(client_fd); return; }
        for(size_t j=0;j<line_len;j++){ if(line[j]=='\r'||line[j]=='\n'){ line[j]='\0'; break; } }
        char *colon = strchr(line, ':'); if(colon){ *colon='\0'; char *name=line; char *value=colon+1; while(*value==' ') value++;
            if (strcasecmp(name, "Content-Length")==0){ content_length = (size_t)strtoul(value, NULL, 10); }
            else if (strcasecmp(name, "Cookie")==0){ strncpy(cookie_hdr, value, sizeof(cookie_hdr)-1); }
            else if (strcasecmp(name, "Expect")==0){ if (strncasecmp(value, "100-continue", 12)==0) expect_100 = 1; }
        }
        free(line);
        pos = line_end + 2;
    }

    // For requests with a body and Expect: 100-continue, send interim response
    int has_body_method = (strcasecmp(method, "POST")==0 || strcasecmp(method, "PUT")==0);
    if (has_body_method && content_length > 0 && expect_100) {
        const char *cont = "HTTP/1.1 100 Continue\r\n\r\n";
        write_all(client_fd, cont, strlen(cont));
    }

    // Read body if needed
    const char *body_from_buf = buf + hdr_end;
    char *body = NULL; size_t body_size = 0;
    if(has_body_method && content_length>0){
        if(content_length > MAX_REQ_SIZE){ send_error_json(client_fd, 413, "Payload too large"); close(client_fd); return; }
        body = malloc(content_length+1); if(!body){ close(client_fd); return; }
        size_t copied = 0;
        size_t hdr_data = used - hdr_end; if(hdr_data > 0){ size_t to_copy = hdr_data; if(to_copy > content_length) to_copy = content_length; memcpy(body, body_from_buf, to_copy); copied += to_copy; }
        while(copied < content_length){ r = read(client_fd, body+copied, content_length-copied); if(r<0){ if(errno==EINTR) continue; free(body); close(client_fd); return; } if(r==0) break; copied += (size_t)r; }
        body[content_length]='\0'; body_size = content_length;
    } else {
        body = strdup(""); body_size = 0;
    }

    // Helper lambdas via macros
#define RESP_ERR(code,msg) do{ send_error_json(client_fd, code, msg); goto done; }while(0)

    // Authentication
    char sess_token[TOKEN_LEN+1]={0}; int has_cookie = get_session_id_from_cookie(cookie_hdr, sess_token);

    // Routing
    if (strcasecmp(method, "POST")==0 && strcmp(path, "/register")==0){
        JObject o; if(parse_json_object(body, body_size, &o)!=0){ RESP_ERR(400, "Invalid JSON"); }
        const char *uname = jobj_get_string(&o, "username"); const char *pwd = jobj_get_string(&o, "password");
        if(!uname || !is_valid_username(uname)){ jobj_free(&o); RESP_ERR(400, "Invalid username"); }
        if(!pwd || strlen(pwd) < MIN_PASSWORD_LEN){ jobj_free(&o); RESP_ERR(400, "Password too short"); }
        pthread_mutex_lock(&db_mutex);
        if(find_user_by_username(uname)){ pthread_mutex_unlock(&db_mutex); jobj_free(&o); RESP_ERR(409, "Username already exists"); }
        ensure_users_cap(); struct User *u=&users[users_count++]; u->id=next_user_id++; u->username=strdup(uname); u->password=strdup(pwd);
        int id=u->id; char escu[256]; json_escape(u->username, escu, sizeof(escu)); pthread_mutex_unlock(&db_mutex);
        jobj_free(&o);
        send_json_response(client_fd, 201, "{\"id\":%d,\"username\":\"%s\"}", id, escu);
        goto done;
    }
    if (strcasecmp(method, "POST")==0 && strcmp(path, "/login")==0){
        JObject o; if(parse_json_object(body, body_size, &o)!=0){ RESP_ERR(400, "Invalid JSON"); }
        const char *uname = jobj_get_string(&o, "username"); const char *pwd = jobj_get_string(&o, "password");
        if(!uname || !pwd){ jobj_free(&o); RESP_ERR(401, "Invalid credentials"); }
        pthread_mutex_lock(&db_mutex); struct User *u=find_user_by_username(uname);
        if(!u || timing_safe_strcmp(u->password, pwd)!=0){ pthread_mutex_unlock(&db_mutex); jobj_free(&o); RESP_ERR(401, "Invalid credentials"); }
        char token[TOKEN_LEN+1]; do{ if(generate_token(token)!=0){ pthread_mutex_unlock(&db_mutex); jobj_free(&o); RESP_ERR(500, "Internal error"); } } while(find_session(token)!=NULL);
        ensure_sessions_cap(); struct Session *s=&sessions[sessions_count++]; memset(s,0,sizeof(*s)); memcpy(s->token, token, TOKEN_LEN+1); s->user_id=u->id; s->valid=1; int uid=u->id; char escu[256]; json_escape(u->username, escu, sizeof(escu)); pthread_mutex_unlock(&db_mutex);
        char set_cookie[256]; snprintf(set_cookie, sizeof(set_cookie), "session_id=%s; Path=/; HttpOnly", token);
        set_cookie_and_send_json(client_fd, 200, set_cookie, "{\"id\":%d,\"username\":\"%s\"}", uid, escu);
        jobj_free(&o); goto done;
    }
    if (strcasecmp(method, "POST")==0 && strcmp(path, "/logout")==0){
        if(!has_cookie){ RESP_ERR(401, "Authentication required"); }
        pthread_mutex_lock(&db_mutex); struct Session *s=find_session(sess_token); if(!s){ pthread_mutex_unlock(&db_mutex); RESP_ERR(401, "Authentication required"); } s->valid=0; pthread_mutex_unlock(&db_mutex);
        send_json_response(client_fd, 200, "{}"); goto done;
    }
    if (strcasecmp(method, "GET")==0 && strcmp(path, "/me")==0){
        if(!has_cookie){ RESP_ERR(401, "Authentication required"); }
        pthread_mutex_lock(&db_mutex); struct Session *s=find_session(sess_token); if(!s){ pthread_mutex_unlock(&db_mutex); RESP_ERR(401, "Authentication required"); } int uid=s->user_id; struct User *u=find_user_by_id(uid); char escu[256]; if(!u){ pthread_mutex_unlock(&db_mutex); RESP_ERR(500, "Internal error"); } json_escape(u->username, escu, sizeof(escu)); pthread_mutex_unlock(&db_mutex);
        send_json_response(client_fd, 200, "{\"id\":%d,\"username\":\"%s\"}", uid, escu); goto done;
    }
    if (strcasecmp(method, "PUT")==0 && strcmp(path, "/password")==0){
        if(!has_cookie){ RESP_ERR(401, "Authentication required"); }
        JObject o; if(parse_json_object(body, body_size, &o)!=0){ RESP_ERR(400, "Invalid JSON"); }
        const char *oldp=jobj_get_string(&o, "old_password"); const char *newp=jobj_get_string(&o, "new_password"); if(!oldp||!newp){ jobj_free(&o); RESP_ERR(401, "Invalid credentials"); }
        if(strlen(newp)<MIN_PASSWORD_LEN){ jobj_free(&o); RESP_ERR(400, "Password too short"); }
        pthread_mutex_lock(&db_mutex); struct Session *s=find_session(sess_token); if(!s){ pthread_mutex_unlock(&db_mutex); jobj_free(&o); RESP_ERR(401, "Authentication required"); }
        struct User *u=find_user_by_id(s->user_id); if(!u || timing_safe_strcmp(u->password, oldp)!=0){ pthread_mutex_unlock(&db_mutex); jobj_free(&o); RESP_ERR(401, "Invalid credentials"); }
        free(u->password); u->password=strdup(newp); pthread_mutex_unlock(&db_mutex); jobj_free(&o);
        send_json_response(client_fd, 200, "{}"); goto done;
    }
    if (strcasecmp(method, "GET")==0 && strcmp(path, "/todos")==0){
        if(!has_cookie){ RESP_ERR(401, "Authentication required"); }
        pthread_mutex_lock(&db_mutex); struct Session *s=find_session(sess_token); if(!s){ pthread_mutex_unlock(&db_mutex); RESP_ERR(401, "Authentication required"); } int uid=s->user_id; // enumerate todos
        // Build JSON array
        char *out=NULL; size_t cap=1024, len=0; out=malloc(cap); if(!out){ pthread_mutex_unlock(&db_mutex); RESP_ERR(500, "Internal error"); }
        #define APPEND_FMT(fmt, ...) do{ char tmp[1024]; int _n=snprintf(tmp,sizeof(tmp),fmt, __VA_ARGS__); if((size_t)(len+_n+1)>cap){ while((size_t)(len+_n+1)>cap) cap*=2; char*nb=realloc(out,cap); if(!nb){ free(out); pthread_mutex_unlock(&db_mutex); RESP_ERR(500, "Internal error"); } out=nb; } memcpy(out+len,tmp,_n); len+=_n; out[len]='\0'; }while(0)
        strcpy(out,"["); len=1;
        int first=1; for(size_t i=0;i<todos_count;i++){ struct Todo*t=todos[i]; if(!t||t->deleted||t->user_id!=uid) continue; char esc_title[1024]; char esc_desc[2048]; json_escape(t->title,esc_title,sizeof(esc_title)); json_escape(t->description? t->description: "", esc_desc, sizeof(esc_desc)); if(!first){ APPEND_FMT("%s", ","); } first=0; APPEND_FMT("{\"id\":%d,\"title\":\"%s\",\"description\":\"%s\",\"completed\":%s,\"created_at\":\"%s\",\"updated_at\":\"%s\"}", t->id, esc_title, esc_desc, t->completed?"true":"false", t->created_at, t->updated_at); }
        APPEND_FMT("%s", "]");
        pthread_mutex_unlock(&db_mutex);
        send_json_response(client_fd, 200, "%s", out); free(out); goto done;
    }
    if (strcasecmp(method, "POST")==0 && strcmp(path, "/todos")==0){
        if(!has_cookie){ RESP_ERR(401, "Authentication required"); }
        JObject o; if(parse_json_object(body, body_size, &o)!=0){ RESP_ERR(400, "Invalid JSON"); }
        const char *title=jobj_get_string(&o, "title"); const char *desc = jobj_get_string(&o, "description"); if(!title || strlen(title)==0){ jobj_free(&o); RESP_ERR(400, "Title is required"); }
        if(!desc) desc="";
        struct Todo *t=calloc(1,sizeof(*t)); if(!t){ jobj_free(&o); RESP_ERR(500, "Internal error"); }
        t->title=strdup(title); t->description=strdup(desc); t->completed=0; iso8601_utc_now(t->created_at); memcpy(t->updated_at,t->created_at,sizeof(t->created_at)); t->deleted=0;
        pthread_mutex_lock(&db_mutex); struct Session *s=find_session(sess_token); if(!s){ pthread_mutex_unlock(&db_mutex); free(t->title); free(t->description); free(t); jobj_free(&o); RESP_ERR(401, "Authentication required"); } t->user_id=s->user_id; t->id=next_todo_id++; ensure_todos_cap(); todos[todos_count++]=t; int id=t->id; int comp=t->completed; char cat[21]; char uat[21]; memcpy(cat,t->created_at,21); memcpy(uat,t->updated_at,21); char esc_title[1024]; char esc_desc[2048]; json_escape(t->title,esc_title,sizeof(esc_title)); json_escape(t->description? t->description: "", esc_desc, sizeof(esc_desc)); pthread_mutex_unlock(&db_mutex);
        jobj_free(&o);
        send_json_response(client_fd, 201, "{\"id\":%d,\"title\":\"%s\",\"description\":\"%s\",\"completed\":%s,\"created_at\":\"%s\",\"updated_at\":\"%s\"}", id, esc_title, esc_desc, comp?"true":"false", cat, uat); goto done;
    }
    if (strncmp(path, "/todos/", 7)==0){
        const char *idstr = path+7; if(strlen(idstr)==0){ RESP_ERR(404, "Not found"); }
        char *endptr=NULL; long id = strtol(idstr, &endptr, 10); if(id<=0 || (endptr && *endptr!='\0')){ RESP_ERR(404, "Not found"); }
        if (strcasecmp(method, "GET")==0){
            if(!has_cookie){ RESP_ERR(401, "Authentication required"); }
            pthread_mutex_lock(&db_mutex); struct Session *s=find_session(sess_token); if(!s){ pthread_mutex_unlock(&db_mutex); RESP_ERR(401, "Authentication required"); } struct Todo *t=find_todo_by_id((int)id); if(!t || t->user_id != s->user_id){ pthread_mutex_unlock(&db_mutex); RESP_ERR(404, "Todo not found"); }
            char esc_title[1024]; char esc_desc[2048]; json_escape(t->title,esc_title,sizeof(esc_title)); json_escape(t->description? t->description: "", esc_desc, sizeof(esc_desc)); int comp=t->completed; char cat[21]; char uat[21]; memcpy(cat,t->created_at,21); memcpy(uat,t->updated_at,21); pthread_mutex_unlock(&db_mutex);
            send_json_response(client_fd, 200, "{\"id\":%ld,\"title\":\"%s\",\"description\":\"%s\",\"completed\":%s,\"created_at\":\"%s\",\"updated_at\":\"%s\"}", id, esc_title, esc_desc, comp?"true":"false", cat, uat); goto done;
        }
        if (strcasecmp(method, "PUT")==0){
            if(!has_cookie){ RESP_ERR(401, "Authentication required"); }
            JObject o; if(parse_json_object(body, body_size, &o)!=0){ RESP_ERR(400, "Invalid JSON"); }
            pthread_mutex_lock(&db_mutex); struct Session *s=find_session(sess_token); if(!s){ pthread_mutex_unlock(&db_mutex); jobj_free(&o); RESP_ERR(401, "Authentication required"); } struct Todo *t=find_todo_by_id((int)id); if(!t || t->user_id != s->user_id){ pthread_mutex_unlock(&db_mutex); jobj_free(&o); RESP_ERR(404, "Todo not found"); }
            if(jobj_has_key(&o, "title")){ const char *nt=jobj_get_string(&o, "title"); if(!nt || strlen(nt)==0){ pthread_mutex_unlock(&db_mutex); jobj_free(&o); RESP_ERR(400, "Title is required"); } free(t->title); t->title=strdup(nt); }
            if(jobj_has_key(&o, "description")){ const char *nd=jobj_get_string(&o, "description"); if(!nd){ pthread_mutex_unlock(&db_mutex); jobj_free(&o); RESP_ERR(400, "Invalid request"); } free(t->description); t->description=strdup(nd); }
            int fb=0; int nb=jobj_get_bool(&o, "completed", &fb); if(fb){ t->completed = nb?1:0; }
            iso8601_utc_now(t->updated_at); char esc_title[1024]; char esc_desc[2048]; json_escape(t->title,esc_title,sizeof(esc_title)); json_escape(t->description? t->description: "", esc_desc, sizeof(esc_desc)); int comp=t->completed; char cat[21]; char uat[21]; memcpy(cat,t->created_at,21); memcpy(uat,t->updated_at,21); pthread_mutex_unlock(&db_mutex);
            jobj_free(&o);
            send_json_response(client_fd, 200, "{\"id\":%ld,\"title\":\"%s\",\"description\":\"%s\",\"completed\":%s,\"created_at\":\"%s\",\"updated_at\":\"%s\"}", id, esc_title, esc_desc, comp?"true":"false", cat, uat); goto done;
        }
        if (strcasecmp(method, "DELETE")==0){
            if(!has_cookie){ RESP_ERR(401, "Authentication required"); }
            pthread_mutex_lock(&db_mutex); struct Session *s=find_session(sess_token); if(!s){ pthread_mutex_unlock(&db_mutex); RESP_ERR(401, "Authentication required"); } struct Todo *t=find_todo_by_id((int)id); if(!t || t->user_id != s->user_id){ pthread_mutex_unlock(&db_mutex); RESP_ERR(404, "Todo not found"); } delete_todo(t); pthread_mutex_unlock(&db_mutex);
            send_no_content_response(client_fd); goto done;
        }
    }

    RESP_ERR(404, "Not found");

#undef RESP_ERR

done:
    if(body) free(body);
    close(client_fd);
}

static void *client_thread(void *arg){ int fd = *(int*)arg; free(arg); handle_connection(fd, ""); return NULL; }

static void sigint_handler(int signo){ (void)signo; running=0; }

static void usage(const char *prog){ fprintf(stderr, "Usage: %s --port PORT\n", prog); }

int main(int argc, char *argv[]){ int port=0; for(int i=1;i<argc;i++){ if(strcmp(argv[i],"--port")==0 && i+1<argc){ port=atoi(argv[++i]); } else if(strcmp(argv[i],"-p")==0 && i+1<argc){ port=atoi(argv[++i]); } else if(strcmp(argv[i],"-h")==0||strcmp(argv[i],"--help")==0){ usage(argv[0]); return 0; } }
    if(port<=0||port>65535){ usage(argv[0]); return 1; }
    signal(SIGINT, sigint_handler); signal(SIGTERM, sigint_handler);
    int s = socket(AF_INET, SOCK_STREAM, 0); if(s<0){ perror("socket"); return 1; }
    int opt=1; setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    struct sockaddr_in addr; memset(&addr,0,sizeof(addr)); addr.sin_family=AF_INET; addr.sin_addr.s_addr = htonl(INADDR_ANY); addr.sin_port = htons((uint16_t)port);
    if(bind(s, (struct sockaddr*)&addr, sizeof(addr))<0){ perror("bind"); return 1; }
    if(listen(s, 128)<0){ perror("listen"); return 1; }
    printf("Server listening on 0.0.0.0:%d\n", port); fflush(stdout);
    while(running){ struct sockaddr_in cli; socklen_t clilen=sizeof(cli); int cfd = accept(s, (struct sockaddr*)&cli, &clilen); if(cfd<0){ if(errno==EINTR) continue; perror("accept"); break; }
        int *pfd = malloc(sizeof(int)); if(!pfd){ close(cfd); continue; } *pfd=cfd; pthread_t th; pthread_create(&th, NULL, client_thread, pfd); pthread_detach(th);
    }
    close(s); return 0; }
