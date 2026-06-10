#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <jansson.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#include <ctype.h>

#define CONTENT_TYPE_JSON "application/json"
#define MAX_USERS 1024
#define MAX_TODOS 8192
#define MAX_SESSIONS 4096
#define READ_BUF_SIZE 8192
#define HDR_MAX 131072

typedef struct {
    int id;
    char username[64];
    char password[128];
} User;

typedef struct {
    int id;
    int user_id;
    char title[256];
    char description[1024];
    int completed;
    char created_at[21];
    char updated_at[21];
} Todo;

typedef struct {
    char token[65];
    int user_id;
    int valid;
} Session;

static User users[MAX_USERS];
static int user_count = 0;
static int next_user_id = 1;

static Todo todos[MAX_TODOS];
static int todo_count = 0;
static int next_todo_id = 1;

static Session sessions[MAX_SESSIONS];
static int session_count = 0;

static int listen_fd = -1;
static int server_port = 8080;

static void iso8601_now(char out[21]) {
    time_t t = time(NULL);
    struct tm gm;
    gmtime_r(&t, &gm);
    strftime(out, 21, "%Y-%m-%dT%H:%M:%SZ", &gm);
}

static int valid_username(const char *u) {
    if (!u) return 0;
    size_t n = strlen(u);
    if (n < 3 || n > 50) return 0;
    for (size_t i = 0; i < n; i++) if (!(isalnum((unsigned char)u[i]) || u[i]=='_')) return 0;
    return 1;
}

static int username_exists(const char *u) {
    for (int i = 0; i < user_count; i++) if (strcmp(users[i].username, u) == 0) return 1;
    return 0;
}

static User* find_user_by_username(const char *u) {
    for (int i = 0; i < user_count; i++) if (strcmp(users[i].username, u) == 0) return &users[i];
    return NULL;
}
static User* find_user_by_id(int id) { for (int i=0;i<user_count;i++) if (users[i].id==id) return &users[i]; return NULL; }
static Todo* find_todo_by_id(int id) { for (int i=0;i<todo_count;i++) if (todos[i].id==id) return &todos[i]; return NULL; }

static void gen_token(char out[65]) {
    static const char *hex = "0123456789abcdef";
    unsigned char buf[32];
    FILE *f = fopen("/dev/urandom", "rb");
    if (f) { size_t r=fread(buf,1,32,f); (void)r; fclose(f);} else { for (int i=0;i<32;i++) buf[i]=(unsigned char)rand(); }
    for (int i=0;i<32;i++){ out[2*i]=hex[(buf[i]>>4)&0xF]; out[2*i+1]=hex[buf[i]&0xF]; }
    out[64]='\0';
}

static Session* find_session(const char *token) {
    for (int i=0;i<session_count;i++) if (sessions[i].valid && strcmp(sessions[i].token, token)==0) return &sessions[i];
    return NULL;
}
static void invalidate_session(const char *token) { for (int i=0;i<session_count;i++) if (strcmp(sessions[i].token, token)==0) sessions[i].valid=0; }

// HTTP utilities

typedef struct { char *data; size_t len; size_t cap; } dynbuf;
static void db_init(dynbuf *b){ b->data=NULL; b->len=0; b->cap=0; }
static int db_append(dynbuf *b, const void *data, size_t n){ if (b->len + n + 1 > b->cap){ size_t nc = b->cap? b->cap*2:4096; while (nc < b->len+n+1) nc*=2; char *p=realloc(b->data,nc); if(!p) return 0; b->data=p; b->cap=nc;} memcpy(b->data+b->len,data,n); b->len+=n; b->data[b->len]='\0'; return 1; }

static int starts_with(const char *s, const char *p){ return strncmp(s,p,strlen(p))==0; }

static const char* status_text(int code){
    switch(code){
        case 200: return "OK";
        case 201: return "Created";
        case 204: return "No Content";
        case 400: return "Bad Request";
        case 401: return "Unauthorized";
        case 404: return "Not Found";
        case 409: return "Conflict";
        case 500: return "Internal Server Error";
        default: return "OK";
    }
}

static int send_response(int fd, int code, const char *body, const char *extra_headers, int is_delete_no_body){
    char hdr[1024];
    int n=0;
    if (is_delete_no_body){
        n=snprintf(hdr,sizeof(hdr),"HTTP/1.1 %d %s\r\nContent-Length: 0\r\nConnection: close\r\n%s\r\n",code,status_text(code), extra_headers?extra_headers:"");
        send(fd,hdr,n,0);
        return 0;
    }
    size_t blen = body?strlen(body):0;
    n=snprintf(hdr,sizeof(hdr),"HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\nConnection: close\r\n%s\r\n",code,status_text(code),CONTENT_TYPE_JSON,blen, extra_headers?extra_headers:"");
    send(fd,hdr,n,0);
    if (blen) send(fd,body,blen,0);
    return 0;
}

static int send_error_json(int fd, int code, const char *msg){ json_t *o=json_object(); json_object_set_new(o,"error",json_string(msg)); char *s=json_dumps(o, JSON_COMPACT); json_decref(o); int r=send_response(fd,code,s,NULL,0); free(s); return r; }

static char* get_header_value(const char *headers, const char *name){
    size_t nlen=strlen(name);
    const char *p=headers;
    while (p && *p){
        const char *e=strstr(p,"\r\n"); if(!e) e=p+strlen(p);
        if (strncasecmp(p,name,nlen)==0 && p[nlen]==':'){
            p+=nlen+1; while (*p==' '||*p=='\t') p++;
            size_t len=(size_t)(e-p);
            char *v=malloc(len+1); if(!v) return NULL; memcpy(v,p,len); v[len]='\0'; return v;
        }
        if (*e=='\0') break;
        p=e+2;
    }
    return NULL;
}

static char* get_cookie_value(const char *cookie_hdr, const char *name){ if(!cookie_hdr) return NULL; size_t nlen=strlen(name); const char *p=cookie_hdr; while (*p){ while (*p==' ') p++; if (strncmp(p,name,nlen)==0 && p[nlen]=='='){ p+=nlen+1; const char *end=strchr(p,';'); size_t len=end?(size_t)(end-p):strlen(p); char *v=malloc(len+1); if(!v) return NULL; memcpy(v,p,len); v[len]='\0'; return v;} const char *sc=strchr(p,';'); if(!sc) break; p=sc+1; } return NULL; }

static int parse_request(int fd, char **method_out, char **path_out, char **headers_out, char **body_out, size_t *body_len_out){
    dynbuf b; db_init(&b);
    char tmp[READ_BUF_SIZE];
    // Read headers until CRLFCRLF
    while (1){
        ssize_t r = recv(fd, tmp, sizeof(tmp), 0);
        if (r < 0){ if (errno==EINTR) continue; free(b.data); return -1; }
        if (r == 0){ break; }
        if (!db_append(&b, tmp, (size_t)r)){ free(b.data); return -1; }
        if (b.len > HDR_MAX){ free(b.data); return -1; }
        char *sep = strstr(b.data, "\r\n\r\n");
        if (sep){
            size_t header_len = (size_t)(sep - b.data) + 2; // end at CRLF
            // parse request line
            char *line_end = strstr(b.data, "\r\n");
            if (!line_end){ free(b.data); return -1; }
            size_t line_len = (size_t)(line_end - b.data);
            char *line = strndup(b.data, line_len);
            char *meth = strtok(line, " ");
            char *path = meth ? strtok(NULL, " ") : NULL;
            if (!meth || !path){ free(line); free(b.data); return -1; }
            *method_out = strdup(meth);
            *path_out = strdup(path);
            free(line);
            // headers block
            size_t headers_block_len = header_len - (line_len + 2);
            char *headers = strndup(b.data + line_len + 2, headers_block_len);
            *headers_out = headers;
            // body
            size_t already = b.len - (header_len + 2);
            char *cl_str = get_header_value(headers, "Content-Length");
            size_t need = 0;
            if (cl_str){ need = (size_t)strtoul(cl_str, NULL, 10); free(cl_str);} else need = 0;
            dynbuf body; db_init(&body);
            if (already > 0){ if (!db_append(&body, sep+4, already)){ free(b.data); free(headers); free(*method_out); free(*path_out); free(body.data); return -1; } }
            while (body.len < need){
                ssize_t rr = recv(fd, tmp, sizeof(tmp), 0);
                if (rr < 0){ if (errno==EINTR) continue; free(b.data); free(headers); free(*method_out); free(*path_out); free(body.data); return -1; }
                if (rr == 0) break;
                if (!db_append(&body, tmp, (size_t)rr)){ free(b.data); free(headers); free(*method_out); free(*path_out); free(body.data); return -1; }
            }
            *body_out = body.data; *body_len_out = body.len;
            free(b.data);
            return 0;
        }
    }
    free(b.data);
    return -1;
}

static int parse_id_from_path(const char *path){ if (starts_with(path, "/todos/")){ const char *p=path+7; if (!*p) return -1; char *end=NULL; long v=strtol(p,&end,10); if (end && *end=='\0' && v>0 && v<INT32_MAX) return (int)v; } return -1; }

static void todo_to_json(const Todo *t, json_t *o){ json_object_set_new(o,"id",json_integer(t->id)); json_object_set_new(o,"title",json_string(t->title)); json_object_set_new(o,"description",json_string(t->description)); json_object_set_new(o,"completed",json_boolean(t->completed)); json_object_set_new(o,"created_at",json_string(t->created_at)); json_object_set_new(o,"updated_at",json_string(t->updated_at)); }

static int require_auth_fd(int fd, const char *headers, int *out_user_id, char **out_token){
    char *cookie = get_header_value(headers, "Cookie");
    char *tok = get_cookie_value(cookie, "session_id");
    free(cookie);
    if (!tok) { send_error_json(fd,401,"Authentication required"); return 0; }
    Session *s = find_session(tok);
    if (!s){ free(tok); send_error_json(fd,401,"Authentication required"); return 0; }
    *out_user_id = s->user_id;
    if (out_token) *out_token = tok; else free(tok);
    return 1;
}

static void handle_client(int fd){
    char *method=NULL, *path=NULL, *headers=NULL, *body=NULL; size_t body_len=0;
    if (parse_request(fd, &method, &path, &headers, &body, &body_len) != 0){ close(fd); return; }

    int code=404; char *resp_body=NULL; char extra_hdrs[512]; extra_hdrs[0]='\0'; int delete_no_body=0;

    if (strcmp(method,"POST")==0 && strcmp(path, "/register")==0){
        json_error_t jerr; json_t *root = (body_len? json_loadb(body, body_len, 0, &jerr): json_object()); if (!root){ send_error_json(fd,400,"Invalid JSON"); goto done; }
        const char *username=NULL, *password=NULL; json_t *ju=json_object_get(root,"username"), *jp=json_object_get(root,"password"); if (json_is_string(ju)) username=json_string_value(ju); if (json_is_string(jp)) password=json_string_value(jp);
        if (!valid_username(username)) { json_decref(root); send_error_json(fd,400,"Invalid username"); goto done; }
        if (!password || strlen(password)<8){ json_decref(root); send_error_json(fd,400,"Password too short"); goto done; }
        if (username_exists(username)){ json_decref(root); send_error_json(fd,409,"Username already exists"); goto done; }
        if (user_count>=MAX_USERS){ json_decref(root); send_error_json(fd,500,"User limit reached"); goto done; }
        User u={0}; u.id=next_user_id++; snprintf(u.username,sizeof(u.username),"%s",username); snprintf(u.password,sizeof(u.password),"%s",password); users[user_count++]=u;
        json_t *out=json_object(); json_object_set_new(out,"id",json_integer(u.id)); json_object_set_new(out,"username",json_string(u.username)); resp_body=json_dumps(out,JSON_COMPACT); json_decref(out); code=201;
        json_decref(root);
    } else if (strcmp(method,"POST")==0 && strcmp(path, "/login")==0){
        json_error_t jerr; json_t *root = (body_len? json_loadb(body, body_len, 0, &jerr): NULL); if (!root){ send_error_json(fd,400,"Invalid JSON"); goto done; }
        const char *username=NULL, *password=NULL; json_t *ju=json_object_get(root,"username"), *jp=json_object_get(root,"password"); if (json_is_string(ju)) username=json_string_value(ju); if (json_is_string(jp)) password=json_string_value(jp);
        User *u=NULL; if (username && password){ u=find_user_by_username(username); if (u && strcmp(u->password,password)!=0) u=NULL; }
        if (!u){ json_decref(root); send_error_json(fd,401,"Invalid credentials"); goto done; }
        if (session_count>=MAX_SESSIONS){ json_decref(root); send_error_json(fd,500,"Session limit reached"); goto done; }
        Session s={0}; gen_token(s.token); s.user_id=u->id; s.valid=1; sessions[session_count++]=s;
        snprintf(extra_hdrs,sizeof(extra_hdrs),"Set-Cookie: session_id=%s; Path=/; HttpOnly\r\n", s.token);
        json_t *out=json_object(); json_object_set_new(out,"id",json_integer(u->id)); json_object_set_new(out,"username",json_string(u->username)); resp_body=json_dumps(out,JSON_COMPACT); json_decref(out); code=200; json_decref(root);
    } else if (strcmp(method,"POST")==0 && strcmp(path, "/logout")==0){
        int uid=0; char *tok=NULL; if (!require_auth_fd(fd, headers, &uid, &tok)) goto done; invalidate_session(tok); free(tok); json_t *out=json_object(); resp_body=json_dumps(out,JSON_COMPACT); json_decref(out); code=200;
    } else if (strcmp(method,"GET")==0 && strcmp(path, "/me")==0){
        int uid=0; if (!require_auth_fd(fd, headers, &uid, NULL)) goto done; User *u=find_user_by_id(uid); if (!u){ send_error_json(fd,401,"Authentication required"); goto done; } json_t *out=json_object(); json_object_set_new(out,"id",json_integer(u->id)); json_object_set_new(out,"username",json_string(u->username)); resp_body=json_dumps(out,JSON_COMPACT); json_decref(out); code=200;
    } else if (strcmp(method,"PUT")==0 && strcmp(path, "/password")==0){
        int uid=0; if (!require_auth_fd(fd, headers, &uid, NULL)) goto done; User *u=find_user_by_id(uid); if (!u){ send_error_json(fd,401,"Authentication required"); goto done; }
        json_error_t jerr; json_t *root = (body_len? json_loadb(body, body_len, 0, &jerr): NULL); if (!root){ send_error_json(fd,400,"Invalid JSON"); goto done; }
        const char *oldp=NULL, *newp=NULL; json_t *jo=json_object_get(root,"old_password"), *jn=json_object_get(root,"new_password"); if (json_is_string(jo)) oldp=json_string_value(jo); if (json_is_string(jn)) newp=json_string_value(jn);
        if (!oldp || strcmp(oldp, u->password)!=0){ json_decref(root); send_error_json(fd,401,"Invalid credentials"); goto done; }
        if (!newp || strlen(newp)<8){ json_decref(root); send_error_json(fd,400,"Password too short"); goto done; }
        snprintf(u->password,sizeof(u->password),"%s",newp); json_decref(root); json_t *out=json_object(); resp_body=json_dumps(out,JSON_COMPACT); json_decref(out); code=200;
    } else if (strcmp(method,"GET")==0 && strcmp(path, "/todos")==0){
        int uid=0; if (!require_auth_fd(fd, headers, &uid, NULL)) goto done; json_t *arr=json_array(); for (int i=0;i<todo_count;i++) if (todos[i].user_id==uid){ json_t *o=json_object(); todo_to_json(&todos[i],o); json_array_append_new(arr,o);} resp_body=json_dumps(arr,JSON_COMPACT); json_decref(arr); code=200;
    } else if (strcmp(method,"POST")==0 && strcmp(path, "/todos")==0){
        int uid=0; if (!require_auth_fd(fd, headers, &uid, NULL)) goto done; json_error_t jerr; json_t *root=(body_len? json_loadb(body,body_len,0,&jerr): NULL); if (!root){ send_error_json(fd,400,"Invalid JSON"); goto done; }
        const char *title=NULL, *desc=""; json_t *jt=json_object_get(root,"title"), *jd=json_object_get(root,"description"); if (json_is_string(jt)) title=json_string_value(jt); if (json_is_string(jd)) desc=json_string_value(jd);
        if (!title || strlen(title)==0){ json_decref(root); send_error_json(fd,400,"Title is required"); goto done; }
        if (todo_count>=MAX_TODOS){ json_decref(root); send_error_json(fd,500,"Todo limit reached"); goto done; }
        Todo t={0}; t.id=next_todo_id++; t.user_id=uid; snprintf(t.title,sizeof(t.title),"%s",title); snprintf(t.description,sizeof(t.description),"%s",desc); t.completed=0; iso8601_now(t.created_at); snprintf(t.updated_at,sizeof(t.updated_at),"%s",t.created_at); todos[todo_count++]=t;
        json_t *o=json_object(); todo_to_json(&t,o); resp_body=json_dumps(o,JSON_COMPACT); json_decref(o); json_decref(root); code=201;
    } else if (starts_with(path, "/todos/") && strcmp(method,"GET")==0){
        int uid=0; if (!require_auth_fd(fd, headers, &uid, NULL)) goto done; int id=parse_id_from_path(path); if (id<=0){ send_error_json(fd,404,"Todo not found"); goto done; } Todo *t=find_todo_by_id(id); if (!t || t->user_id!=uid){ send_error_json(fd,404,"Todo not found"); goto done; } json_t *o=json_object(); todo_to_json(t,o); resp_body=json_dumps(o,JSON_COMPACT); json_decref(o); code=200;
    } else if (starts_with(path, "/todos/") && strcmp(method,"PUT")==0){
        int uid=0; if (!require_auth_fd(fd, headers, &uid, NULL)) goto done; int id=parse_id_from_path(path); if (id<=0){ send_error_json(fd,404,"Todo not found"); goto done; } Todo *t=find_todo_by_id(id); if (!t || t->user_id!=uid){ send_error_json(fd,404,"Todo not found"); goto done; }
        json_error_t jerr; json_t *root=(body_len? json_loadb(body,body_len,0,&jerr): json_object()); if (!root){ send_error_json(fd,400,"Invalid JSON"); goto done; }
        json_t *jt=json_object_get(root,"title"); json_t *jd=json_object_get(root,"description"); json_t *jc=json_object_get(root,"completed");
        if (jt){ if (!json_is_string(jt) || strlen(json_string_value(jt))==0){ json_decref(root); send_error_json(fd,400,"Title is required"); goto done; } snprintf(t->title,sizeof(t->title),"%s",json_string_value(jt)); }
        if (jd){ if (!json_is_string(jd)){ json_decref(root); send_error_json(fd,400,"Invalid JSON"); goto done; } snprintf(t->description,sizeof(t->description),"%s",json_string_value(jd)); }
        if (jc){ if (!json_is_boolean(jc)){ json_decref(root); send_error_json(fd,400,"Invalid JSON"); goto done; } t->completed = json_boolean_value(jc)?1:0; }
        iso8601_now(t->updated_at); json_decref(root); json_t *o=json_object(); todo_to_json(t,o); resp_body=json_dumps(o,JSON_COMPACT); json_decref(o); code=200;
    } else if (starts_with(path, "/todos/") && strcmp(method,"DELETE")==0){
        int uid=0; if (!require_auth_fd(fd, headers, &uid, NULL)) goto done; int id=parse_id_from_path(path); if (id<=0){ send_error_json(fd,404,"Todo not found"); goto done; } Todo *t=find_todo_by_id(id); if (!t || t->user_id!=uid){ send_error_json(fd,404,"Todo not found"); goto done; }
        int idx=-1; for (int i=0;i<todo_count;i++) if (todos[i].id==id){ idx=i; break; } if (idx>=0){ for (int i=idx+1;i<todo_count;i++) todos[i-1]=todos[i]; todo_count--; }
        code=204; delete_no_body=1; // no Content-Type header
    } else {
        send_error_json(fd,404,"Not found"); goto done;
    }

    if (resp_body){ send_response(fd,code,resp_body, extra_hdrs[0]?extra_hdrs:NULL, 0); free(resp_body);} else { send_response(fd,code,"", extra_hdrs[0]?extra_hdrs:NULL, delete_no_body); }

 done:
    free(method); free(path); free(headers); free(body);
    close(fd);
}

static void cleanup(int sig){ (void)sig; if (listen_fd!=-1) close(listen_fd); exit(0); }

int main(int argc, char **argv){
    for (int i=1;i<argc;i++){ if (strcmp(argv[i],"--port")==0 && i+1<argc){ server_port=atoi(argv[++i]); }}
    signal(SIGINT, cleanup); signal(SIGTERM, cleanup);
    listen_fd = socket(AF_INET, SOCK_STREAM, 0); if (listen_fd<0){ perror("socket"); return 1; }
    int opt=1; setsockopt(listen_fd,SOL_SOCKET,SO_REUSEADDR,&opt,sizeof(opt));
    struct sockaddr_in addr; memset(&addr,0,sizeof(addr)); addr.sin_family=AF_INET; addr.sin_addr.s_addr=htonl(INADDR_ANY); addr.sin_port=htons((uint16_t)server_port);
    if (bind(listen_fd,(struct sockaddr*)&addr,sizeof(addr))<0){ perror("bind"); return 1; }
    if (listen(listen_fd, 64)<0){ perror("listen"); return 1; }
    printf("Server listening on 0.0.0.0:%d\n", server_port); fflush(stdout);
    while (1){ int cfd = accept(listen_fd, NULL, NULL); if (cfd<0){ if (errno==EINTR) continue; perror("accept"); break; } handle_client(cfd); }
    cleanup(0); return 0;
}
