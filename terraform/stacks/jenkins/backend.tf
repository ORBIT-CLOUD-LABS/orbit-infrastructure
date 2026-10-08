terraform {
  # conn_str은 비밀번호를 포함하므로 여기에 두지 않는다.
  # terraform init -backend-config=backend-config/astra.conf 로 전달한다.
  # (backend-config/astra.conf.example 참고, 실제 파일은 git에 커밋하지 않는다)
  # 업무 스택(environments/astra)과 같은 DB를 쓰고 schema로 state를 분리한다.
  backend "pg" {
    schema_name = "terraform_remote_state_jenkins"
  }
}
