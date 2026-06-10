#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define BACKLOG 128
#define READ_TIMEOUT_SEC 10
#define MAX_REQ 131072

struct User {
    int id;
    char username[51];
    char password[256];
    struct User* next;
};

struct Todo {
    int id;
    int owner_id;
    char title[256];
    char description[1024];
    int completed;
    time_t created_at;
    time_t updated_at;
    struct Todo* next;
};

struct Session {
    char token[65];
    int user_id;
    struct Session* next;
};

static struct User* users_head = NULL;
static struct Todo* todos_head = NULL;
static struct Session* sessions_head = NULL;
static int next_user_id = 1;
static int next_todo_id = 1;
static pthread_mutex_t data_mutex = PTHREAD_MUTEX_INITIALIZER;
static int listen_fd = -1;
static volatile sig_atomic_t stop_flag = 0;

static void handle_sigint(int sig){ (void)sig; stop_flag = 1; if(listen_fd>=0) close(listen_fd); }

static void time_to_iso8601(time_t t, char out[21]) {
    struct tm tm;
    gmtime_r(&t, &tm);
    strftime(out, 21, "%Y-%m-%dT%H:%M:%SZ", &tm);
}

static int valid_username(const char* s) {
    size_t len = strlen(s);
    if (len < 3 || len > 50) return 0;
    for (size_t i=0;i<len;i++) if (!(isalnum((unsigned char)s[i]) || s[i]=='_')) return 0;
    return 1;
}

static struct User* find_user_by_username(const char* username) {
    for (struct User* u = users_head; u; u=u->next) if (strcmp(u->username, username)==0) return u; return NULL;
}
static struct User* find_user_by_id(int id) {
    for (struct User* u = users_head; u; u=u->next) if (u->id==id) return u; return NULL;
}
static struct Todo* find_todo_by_id(int id) {
    for (struct Todo* t = todos_head; t; t=t->next) if (t->id==id) return t; return NULL;
}

static void gen_token(char out[65]) {
    static const char* hex = "0123456789abcdef";
    unsigned char bytes[32];
    FILE* f = fopen("/dev/urandom", "rb");
    if (f) { fread(bytes,1,32,f); fclose(f);} else { for (int i=0;i<32;i++) bytes[i] = rand() & 0xFF; }
    for (int i=0;i<32;i++){ out[2*i]=hex[(bytes[i]>>4)&0xF]; out[2*i+1]=hex[bytes[i]&0xF]; }
    out[64]='\0';
}

static struct Session* find_session(const char* token){ for(struct Session* s=sessions_head;s;s=s->next) if(strcmp(s->token,token)==0) return s; return NULL; }
static int remove_session(const char* token){ struct Session* prev=NULL; for(struct Session* s=sessions_head;s;prev=s,s=s->next){ if(strcmp(s->token,token)==0){ if(prev) prev->next=s->next; else sessions_head=s->next; free(s); return 1; } } return 0; }
static struct Session* create_session(int user_id){ struct Session* s=malloc(sizeof(*s)); if(!s) return NULL; gen_token(s->token); s->user_id=user_id; s->next=sessions_head; sessions_head=s; return s; }

static void json_escape(const char* in, char* out, size_t outsz){ size_t j=0; for(size_t i=0; in[i] && j+2<outsz; i++){ unsigned char c=in[i]; if(c=='"' || c=='\\'){ if(j+2>=outsz) break; out[j++]='\\'; out[j++]=c; }
        else if(c=='\n'){ if(j+2>=outsz) break; out[j++]='\\'; out[j++]='n'; }
        else if(c=='\r'){ if(j+2>=outsz) break; out[j++]='\\'; out[j++]='r'; }
        else if(c=='\t'){ if(j+2>=outsz) break; out[j++]='\\'; out[j++]='t'; }
        else if(c<0x20){ if(j+6>=outsz) break; j+=snprintf(out+j,outsz-j,"\\u%04x", c); }
        else { out[j++]=c; }
    } out[j]='\0'; }

struct HttpRequest{
    char method[8];
    char path[1024];
    char cookie[2048];
    size_t content_length;
    char* body;
};

static int read_line(int fd, char* buf, size_t max){ size_t n=0; while(n+1<max){ char c; ssize_t r=recv(fd,&c,1,0); if(r<=0) return -1; if(c=='\r') continue; if(c=='\n'){ buf[n]='\0'; return (int)n; } buf[n++]=c; } buf[max-1]='\0'; return (int)n; }

static int parse_request(int fd, struct HttpRequest* req){ memset(req,0,sizeof(*req)); req->content_length=0; req->body=NULL; char line[4096]; if(read_line(fd,line,sizeof(line))<0) return -1; // request line
    char ver[16]; if(sscanf(line,"%7s %1023s %15s", req->method, req->path, ver)!=3) return -1;
    // headers
    while(1){ int l=read_line(fd,line,sizeof(line)); if(l<0) return -1; if(l==0) break; char* p=line; while(*p==' ') p++; if(strncasecmp(p,"Content-Length:",15)==0){ p+=15; while(*p==' '||*p=='\t') p++; req->content_length=(size_t)strtoul(p,NULL,10); }
        else if(strncasecmp(p,"Cookie:",7)==0){ p+=7; while(*p==' '||*p=='\t') p++; strncpy(req->cookie,p,sizeof(req->cookie)-1); }
    }
    if (req->content_length>0){ req->body = malloc(req->content_length+1); if(!req->body) return -1; size_t got=0; while(got<req->content_length){ ssize_t r=recv(fd, req->body+got, req->content_length-got, 0); if(r<=0){ free(req->body); req->body=NULL; return -1; } got+=r; } req->body[req->content_length]='\0'; }
    return 0; }

static void send_response(int fd, int status, const char* status_text, const char* content_type, const char* body){ char header[4096]; size_t blen = body? strlen(body):0; int n = snprintf(header,sizeof(header),
        "HTTP/1.1 %d %s\r\nConnection: close\r\n%sContent-Length: %zu\r\n\r\n",
        status, status_text,
        (content_type? ( (strcmp(content_type,"")!=0)?"Content-Type: application/json\r\n":"" ) : "Content-Type: application/json\r\n"),
        blen);
    send(fd, header, n, 0);
    if (blen>0) send(fd, body, blen, 0);
}

static void send_response_with_cookie(int fd, int status, const char* status_text, const char* body, const char* cookie){ char header[8192]; size_t blen = body? strlen(body):0; int n = snprintf(header,sizeof(header),
        "HTTP/1.1 %d %s\r\nConnection: close\r\nContent-Type: application/json\r\nSet-Cookie: %s\r\nContent-Length: %zu\r\n\r\n",
        status, status_text, cookie, blen);
    send(fd, header, n, 0);
    if (blen>0) send(fd, body, blen, 0);
}

static void send_error_json(int fd, int status, const char* message){ char esc[1024]; json_escape(message, esc, sizeof(esc)); char buf[1200]; snprintf(buf,sizeof(buf),"{\"error\":\"%s\"}", esc); send_response(fd,status,"Error", "application/json", buf); }

static const char* get_cookie_session_id(const char* cookie_header){ if(!cookie_header||!*cookie_header) return NULL; const char* p = strstr(cookie_header,"session_id="); if(!p) return NULL; p+=11; static __thread char token[128]; size_t i=0; while(*p && *p!=';' && !isspace((unsigned char)*p) && i+1<sizeof(token)){ token[i++]=*p++; } token[i]='\0'; return token; }

// Minimal JSON key lookup for string
static int json_get_string(const char* body, const char* key, char* out, size_t outsz){ if(!body||!key||!out||outsz==0) return 0; char pattern[128]; snprintf(pattern,sizeof(pattern),"\"%s\"", key); const char* p = strstr(body, pattern); if(!p) return 0; p += strlen(pattern); while(*p && (*p==':' || isspace((unsigned char)*p))) p++; if(*p!='\"') return 0; p++; size_t j=0; while(*p && *p!='\"' && j+1<outsz){ if(*p=='\\' && p[1]){ p++; char c=*p; if(c=='n') out[j++]='\n'; else if(c=='r') out[j++]='\r'; else if(c=='t') out[j++]='\t'; else out[j++]=c; p++; continue; } out[j++]=*p++; } out[j]='\0'; return 1; }

static int json_get_bool(const char* body, const char* key, int* out_present, int* out_val){ if(!body||!key||!out_present||!out_val) return 0; char pattern[128]; snprintf(pattern,sizeof(pattern),"\"%s\"", key); const char* p = strstr(body, pattern); if(!p){ *out_present=0; return 1; } p += strlen(pattern); while(*p && (*p==':' || isspace((unsigned char)*p))) p++; if(strncmp(p,"true",4)==0){ *out_present=1; *out_val=1; return 1; } if(strncmp(p,"false",5)==0){ *out_present=1; *out_val=0; return 1; } *out_present=1; return 0; }

static int require_auth_fd(int fd, const char* cookie_header, int* out_user_id, char* out_token, size_t out_token_sz){ const char* token = get_cookie_session_id(cookie_header); if(!token||!*token){ send_error_json(fd,401,"Authentication required"); return -1; } pthread_mutex_lock(&data_mutex); struct Session* s = find_session(token); if(!s){ pthread_mutex_unlock(&data_mutex); send_error_json(fd,401,"Authentication required"); return -1; } int uid = s->user_id; pthread_mutex_unlock(&data_mutex); if(out_user_id) *out_user_id = uid; if(out_token){ strncpy(out_token, token, out_token_sz-1); out_token[out_token_sz-1]='\0'; } return 0; }

static void handle_register(int fd, struct HttpRequest* req){ char username[128]={0}, password[256]={0}; if(!req->body || !json_get_string(req->body,"username",username,sizeof(username)) || !json_get_string(req->body,"password",password,sizeof(password))){ send_error_json(fd,400,"Invalid JSON"); return; }
    if(!valid_username(username)){ send_error_json(fd,400,"Invalid username"); return; }
    if(strlen(password)<8){ send_error_json(fd,400,"Password too short"); return; }
    pthread_mutex_lock(&data_mutex);
    if(find_user_by_username(username)){ pthread_mutex_unlock(&data_mutex); send_error_json(fd,409,"Username already exists"); return; }
    struct User* u = calloc(1,sizeof(*u)); if(!u){ pthread_mutex_unlock(&data_mutex); send_error_json(fd,500,"Server error"); return; }
    u->id = next_user_id++; strncpy(u->username,username,sizeof(u->username)-1); strncpy(u->password,password,sizeof(u->password)-1); u->next = users_head; users_head=u; int uid=u->id; char uname[64]; strncpy(uname,u->username,sizeof(uname)-1); pthread_mutex_unlock(&data_mutex);
    char esc[128]; json_escape(uname, esc, sizeof(esc)); char body[256]; snprintf(body,sizeof(body),"{\"id\":%d,\"username\":\"%s\"}", uid, esc); send_response(fd,201,"Created","application/json", body);
}

static void handle_login(int fd, struct HttpRequest* req){ char username[128]={0}, password[256]={0}; if(!req->body || !json_get_string(req->body,"username",username,sizeof(username)) || !json_get_string(req->body,"password",password,sizeof(password))){ send_error_json(fd,400,"Invalid JSON"); return; }
    pthread_mutex_lock(&data_mutex);
    struct User* u = find_user_by_username(username);
    if(!u || strcmp(u->password,password)!=0){ pthread_mutex_unlock(&data_mutex); send_error_json(fd,401,"Invalid credentials"); return; }
    struct Session* s = create_session(u->id);
    if(!s){ pthread_mutex_unlock(&data_mutex); send_error_json(fd,500,"Server error"); return; }
    int uid=u->id; char uname[64]; strncpy(uname,u->username,sizeof(uname)-1); pthread_mutex_unlock(&data_mutex);
    char esc[128]; json_escape(uname, esc, sizeof(esc)); char body[256]; snprintf(body,sizeof(body),"{\"id\":%d,\"username\":\"%s\"}", uid, esc);
    char cookie[256]; snprintf(cookie,sizeof(cookie),"session_id=%s; Path=/; HttpOnly", s->token);
    send_response_with_cookie(fd,200,"OK", body, cookie);
}

static void handle_logout(int fd, struct HttpRequest* req){ int uid=0; char token[128]; if(require_auth_fd(fd, req->cookie, &uid, token, sizeof(token))<0) return; pthread_mutex_lock(&data_mutex); remove_session(token); pthread_mutex_unlock(&data_mutex); send_response(fd,200,"OK","application/json","{}"); }

static void handle_me(int fd, struct HttpRequest* req){ int uid=0; if(require_auth_fd(fd, req->cookie, &uid, NULL, 0)<0) return; pthread_mutex_lock(&data_mutex); struct User* u = find_user_by_id(uid); char uname[64]={0}; if(u) strncpy(uname,u->username,sizeof(uname)-1); pthread_mutex_unlock(&data_mutex); if(!u){ send_error_json(fd,500,"Server error"); return; } char esc[128]; json_escape(uname, esc, sizeof(esc)); char body[256]; snprintf(body,sizeof(body),"{\"id\":%d,\"username\":\"%s\"}", uid, esc); send_response(fd,200,"OK","application/json", body); }

static void handle_password(int fd, struct HttpRequest* req){ int uid=0; if(require_auth_fd(fd, req->cookie, &uid, NULL, 0)<0) return; char oldp[256]={0}, newp[256]={0}; if(!req->body || !json_get_string(req->body,"old_password",oldp,sizeof(oldp)) || !json_get_string(req->body,"new_password",newp,sizeof(newp))){ send_error_json(fd,400,"Invalid JSON"); return; } if(strlen(newp)<8){ send_error_json(fd,400,"Password too short"); return; } pthread_mutex_lock(&data_mutex); struct User* u = find_user_by_id(uid); if(!u || strcmp(u->password,oldp)!=0){ pthread_mutex_unlock(&data_mutex); send_error_json(fd,401,"Invalid credentials"); return; } strncpy(u->password,newp,sizeof(u->password)-1); pthread_mutex_unlock(&data_mutex); send_response(fd,200,"OK","application/json","{}"); }

static int cmp_todo_ptrs(const void* a, const void* b){ const struct Todo* ta=*(const struct Todo* const*)a; const struct Todo* tb=*(const struct Todo* const*)b; return (ta->id>tb->id)-(ta->id<tb->id); }

static void todo_json(const struct Todo* t, char* out, size_t outsz){ char etitle[512], edesc[2048], c1[21], c2[21]; json_escape(t->title, etitle, sizeof(etitle)); json_escape(t->description, edesc, sizeof(edesc)); time_to_iso8601(t->created_at, c1); time_to_iso8601(t->updated_at, c2); snprintf(out,outsz,"{\"id\":%d,\"title\":\"%s\",\"description\":\"%s\",\"completed\":%s,\"created_at\":\"%s\",\"updated_at\":\"%s\"}", t->id, etitle, edesc, t->completed?"true":"false", c1, c2); }

static void handle_todos_list(int fd, struct HttpRequest* req){ int uid=0; if(require_auth_fd(fd, req->cookie, &uid, NULL, 0)<0) return; pthread_mutex_lock(&data_mutex); size_t cap=16,n=0; struct Todo** arr = malloc(cap*sizeof(*arr)); if(!arr){ pthread_mutex_unlock(&data_mutex); send_error_json(fd,500,"Server error"); return; } for(struct Todo* t=todos_head;t;t=t->next){ if(t->owner_id==uid){ if(n==cap){ cap*=2; struct Todo** tmp=realloc(arr,cap*sizeof(*arr)); if(!tmp){ free(arr); pthread_mutex_unlock(&data_mutex); send_error_json(fd,500,"Server error"); return; } arr=tmp; } arr[n++]=t; } } qsort(arr,n,sizeof(*arr),cmp_todo_ptrs); size_t bufsz = 64 + n*4096; char* body = malloc(bufsz); if(!body){ free(arr); pthread_mutex_unlock(&data_mutex); send_error_json(fd,500,"Server error"); return; } size_t off=0; body[off++]='['; for(size_t i=0;i<n;i++){ char item[4096]; todo_json(arr[i], item, sizeof(item)); size_t ilen=strlen(item); if(off+ilen+2>=bufsz){ bufsz*=2; char* nb=realloc(body,bufsz); if(!nb){ free(arr); free(body); pthread_mutex_unlock(&data_mutex); send_error_json(fd,500,"Server error"); return; } body=nb; }
        if(i>0) body[off++]=','; memcpy(body+off,item,ilen); off+=ilen; }
    body[off++]=']'; body[off]='\0'; free(arr); pthread_mutex_unlock(&data_mutex); send_response(fd,200,"OK","application/json", body); free(body); }

static void handle_todos_create(int fd, struct HttpRequest* req){ int uid=0; if(require_auth_fd(fd, req->cookie, &uid, NULL, 0)<0) return; char title[256]={0}, desc[1024]={0}; if(!req->body || !json_get_string(req->body,"title",title,sizeof(title))){ send_error_json(fd,400,"Title is required"); return; } if(req->body) json_get_string(req->body,"description",desc,sizeof(desc)); pthread_mutex_lock(&data_mutex); struct Todo* t = calloc(1,sizeof(*t)); if(!t){ pthread_mutex_unlock(&data_mutex); send_error_json(fd,500,"Server error"); return; } t->id = next_todo_id++; t->owner_id=uid; strncpy(t->title,title,sizeof(t->title)-1); strncpy(t->description,desc,sizeof(t->description)-1); t->completed=0; t->created_at=t->updated_at=time(NULL); t->next=todos_head; todos_head=t; char item[4096]; todo_json(t,item,sizeof(item)); pthread_mutex_unlock(&data_mutex); send_response(fd,201,"Created","application/json", item); }

static int parse_todo_id(const char* path){ if(strncmp(path,"/todos/",8-1)!=0) return -1; const char* s = path+7; if(!*s) return -1; char* end=NULL; long v=strtol(s,&end,10); if(v<=0 || (end && *end!='\0')) return -1; return (int)v; }

static void handle_todo_get(int fd, struct HttpRequest* req, int id){ int uid=0; if(require_auth_fd(fd, req->cookie, &uid, NULL, 0)<0) return; pthread_mutex_lock(&data_mutex); struct Todo* t = find_todo_by_id(id); if(!t || t->owner_id!=uid){ pthread_mutex_unlock(&data_mutex); send_error_json(fd,404,"Todo not found"); return; } char item[4096]; todo_json(t,item,sizeof(item)); pthread_mutex_unlock(&data_mutex); send_response(fd,200,"OK","application/json", item); }

static void handle_todo_put(int fd, struct HttpRequest* req, int id){ int uid=0; if(require_auth_fd(fd, req->cookie, &uid, NULL, 0)<0) return; if(!req->body){ send_error_json(fd,400,"Invalid JSON"); return; } pthread_mutex_lock(&data_mutex); struct Todo* t = find_todo_by_id(id); if(!t || t->owner_id!=uid){ pthread_mutex_unlock(&data_mutex); send_error_json(fd,404,"Todo not found"); return; } char title[256]; int has_title = json_get_string(req->body,"title",title,sizeof(title)); if(has_title){ if(strlen(title)==0){ pthread_mutex_unlock(&data_mutex); send_error_json(fd,400,"Title is required"); return; } strncpy(t->title,title,sizeof(t->title)-1); t->title[sizeof(t->title)-1]='\0'; }
    char desc[1024]; if(json_get_string(req->body,"description",desc,sizeof(desc))){ strncpy(t->description,desc,sizeof(t->description)-1); t->description[sizeof(t->description)-1]='\0'; }
    int present=0, bval=0; if(json_get_bool(req->body,"completed",&present,&bval) && present){ t->completed=bval?1:0; }
    t->updated_at=time(NULL); char item[4096]; todo_json(t,item,sizeof(item)); pthread_mutex_unlock(&data_mutex); send_response(fd,200,"OK","application/json", item); }

static void handle_todo_delete(int fd, struct HttpRequest* req, int id){ int uid=0; if(require_auth_fd(fd, req->cookie, &uid, NULL, 0)<0) return; pthread_mutex_lock(&data_mutex); struct Todo* prev=NULL; struct Todo* t=todos_head; while(t && t->id!=id){ prev=t; t=t->next; } if(!t || t->owner_id!=uid){ pthread_mutex_unlock(&data_mutex); send_error_json(fd,404,"Todo not found"); return; } if(prev) prev->next=t->next; else todos_head=t->next; free(t); pthread_mutex_unlock(&data_mutex); // 204 no content, no Content-Type
    char header[256]; int n=snprintf(header,sizeof(header),"HTTP/1.1 204 No Content\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"); send(fd,header,n,0); }

static void* client_thread(void* arg){ int fd = *(int*)arg; free(arg); struct HttpRequest req; if(parse_request(fd,&req)!=0){ close(fd); return NULL; }
    if(strcmp(req.method,"POST")==0 && strcmp(req.path,"/register")==0){ handle_register(fd,&req); }
    else if(strcmp(req.method,"POST")==0 && strcmp(req.path,"/login")==0){ handle_login(fd,&req); }
    else if(strcmp(req.method,"POST")==0 && strcmp(req.path,"/logout")==0){ handle_logout(fd,&req); }
    else if(strcmp(req.method,"GET")==0 && strcmp(req.path,"/me")==0){ handle_me(fd,&req); }
    else if(strcmp(req.method,"PUT")==0 && strcmp(req.path,"/password")==0){ handle_password(fd,&req); }
    else if(strcmp(req.method,"GET")==0 && strcmp(req.path,"/todos")==0){ handle_todos_list(fd,&req); }
    else if(strcmp(req.method,"POST")==0 && strcmp(req.path,"/todos")==0){ handle_todos_create(fd,&req); }
    else if(strncmp(req.path,"/todos/",7)==0){ int id = parse_todo_id(req.path); if(id<=0){ send_error_json(fd,404,"Not found"); }
        else if(strcmp(req.method,"GET")==0){ handle_todo_get(fd,&req,id); }
        else if(strcmp(req.method,"PUT")==0){ handle_todo_put(fd,&req,id); }
        else if(strcmp(req.method,"DELETE")==0){ handle_todo_delete(fd,&req,id); }
        else { send_error_json(fd,405,"Method not allowed"); }
    }
    else { send_error_json(fd,404,"Not found"); }

    if(req.body) free(req.body); close(fd); return NULL; }

int main(int argc, char* argv[]){ int port=0; for(int i=1;i<argc;i++){ if(strcmp(argv[i],"--port")==0 && i+1<argc){ port=atoi(argv[i+1]); i++; } }
    if(port<=0){ fprintf(stderr,"Usage: %s --port PORT\n", argv[0]); return 1; }
    signal(SIGINT, handle_sigint);
    listen_fd = socket(AF_INET, SOCK_STREAM, 0); if(listen_fd<0){ perror("socket"); return 1; }
    int opt=1; setsockopt(listen_fd,SOL_SOCKET,SO_REUSEADDR,&opt,sizeof(opt));
    struct sockaddr_in addr; memset(&addr,0,sizeof(addr)); addr.sin_family=AF_INET; addr.sin_addr.s_addr=htonl(INADDR_ANY); addr.sin_port=htons((uint16_t)port);
    if(bind(listen_fd,(struct sockaddr*)&addr,sizeof(addr))<0){ perror("bind"); return 1; }
    if(listen(listen_fd,BACKLOG)<0){ perror("listen"); return 1; }
    fprintf(stdout,"Server listening on 0.0.0.0:%d\n", port); fflush(stdout);
    while(!stop_flag){ struct sockaddr_in cli; socklen_t cl=sizeof(cli); int* cfd = malloc(sizeof(int)); if(!cfd){ sleep(1); continue; } *cfd = accept(listen_fd,(struct sockaddr*)&cli,&cl); if(*cfd<0){ free(cfd); if(errno==EINTR) continue; perror("accept"); break; }
        pthread_t th; pthread_create(&th,NULL,client_thread,cfd); pthread_detach(th); }
    if(listen_fd>=0) close(listen_fd); return 0; }
