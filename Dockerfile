FROM node:24-alpine AS builder

RUN apk update && \
    apk add --no-cache git ffmpeg wget curl bash openssl

LABEL version="2.3.1" description="Api to control whatsapp features through http requests." 
LABEL maintainer="Davidson Gomes" git="https://github.com/DavidsonGomes"
LABEL contact="contato@evolution-api.com"

WORKDIR /evolution

COPY ./package*.json ./
COPY ./patches ./patches
COPY ./tsconfig.json ./
COPY ./tsup.config.ts ./

RUN npm ci

# Aplica o patch-package explicitamente, sem depender só do hook
# "postinstall" do npm ci: se o ambiente de build pular devDependencies
# por qualquer motivo (ex.: NODE_ENV=production setado no build, que faz
# o npm omitir devDependencies — patch-package JÁ foi movido pra
# "dependencies" no package.json/package-lock.json por causa disso, mas
# este passo fica como segunda garantia, não como único ponto de falha)
# o build já falha aqui, com uma mensagem clara, em vez de seguir
# silenciosamente com o Baileys sem patch.
RUN npx patch-package

# Verificação que FALHA o build se o patch de
# patches/baileys+7.0.0-rc14.patch não tiver sido aplicado de verdade.
# Os 3 arquivos que o patch toca JÁ EXISTEM no baileys@7.0.0-rc14 nativo
# (nenhum é criado do zero — confirmado lendo o diff --git: todos têm
# "index <hash>..<hash> 100644", não "new file mode") — então checar só
# "o arquivo existe" (ex. Utils/companion-reg-client-utils.js) ou só "a
# string aparece pelo menos uma vez" (ex. "primary_identity_pub", que já
# existe 1x no arquivo original mesmo sem patch nenhum) daria falso
# positivo e deixaria passar um build sem patch. Cada checagem abaixo usa
# uma marca confirmada como AUSENTE no pacote original (testado contra um
# node_modules/baileys limpo, sem patch) e presente só depois de aplicado:
# - messages-recv.js: a guarda inteira que o patch ADICIONA (a 2ª
#   ocorrência de 'primary_identity_pub' no arquivo, não a 1ª, que já
#   existia antes do patch).
# - socket.js: "companion_reg_refresh" não existe no arquivo original.
# - companion-reg-client-utils.js: idem — "companion_reg_refresh" só
#   aparece aqui depois do patch (o arquivo original já existe, mas sem
#   essa string).
RUN ( \
      grep -qF "getBinaryNodeChildBuffer(linkCodeCompanionReg, 'primary_identity_pub')) { break; }" node_modules/baileys/lib/Socket/messages-recv.js && \
      grep -q "companion_reg_refresh" node_modules/baileys/lib/Socket/socket.js && \
      grep -q "companion_reg_refresh" node_modules/baileys/lib/Utils/companion-reg-client-utils.js \
    ) || ( \
      echo "PATCH NAO APLICADO: baileys+7.0.0-rc14.patch nao foi aplicado em node_modules/baileys (ver patches/baileys+7.0.0-rc14.patch)" && \
      exit 1 \
    )

COPY ./src ./src
COPY ./public ./public
COPY ./prisma ./prisma
COPY ./manager ./manager
COPY ./.env.example ./.env
COPY ./runWithProvider.js ./

COPY ./Docker ./Docker

RUN chmod +x ./Docker/scripts/* && dos2unix ./Docker/scripts/*

RUN ./Docker/scripts/generate_database.sh

RUN npm run build

FROM node:24-alpine AS final

RUN apk update && \
    apk add tzdata ffmpeg bash openssl

ENV TZ=America/Sao_Paulo
ENV DOCKER_ENV=true

WORKDIR /evolution

COPY --from=builder /evolution/package.json ./package.json
COPY --from=builder /evolution/package-lock.json ./package-lock.json

COPY --from=builder /evolution/node_modules ./node_modules
COPY --from=builder /evolution/dist ./dist
COPY --from=builder /evolution/prisma ./prisma
COPY --from=builder /evolution/manager ./manager
COPY --from=builder /evolution/public ./public
COPY --from=builder /evolution/.env ./.env
COPY --from=builder /evolution/Docker ./Docker
COPY --from=builder /evolution/runWithProvider.js ./runWithProvider.js
COPY --from=builder /evolution/tsup.config.ts ./tsup.config.ts

ENV DOCKER_ENV=true

EXPOSE 8080

ENTRYPOINT ["/bin/bash", "-c", ". ./Docker/scripts/deploy_database.sh && npm run start:prod" ]
