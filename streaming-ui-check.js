/***

Thanks to & modified from
1. https://gist.githubusercontent.com/Hyseen/b06e911a41036ebc36acf04ddebe7b9a/raw/nf_check.js
2. https://github.com/AtlantisGawrGura/Quantumult-X-Scripts/blob/main/media.js
3. https://github.com/CoiaPrant/MediaUnlock_Test/blob/main/check.sh
4. https://github.com/Netflixxp/chatGPT/blob/main/chat.sh

For Quantumult-X 598+ ONLY!!

[task_local]

event-interaction https://raw.githubusercontent.com/YOUR_REPO/streaming-ui-check.js, tag=Check Media, img-url=arrowtriangle.right.square.system, enabled=true

***/

const BASE_URL = "https://www.netflix.com/title/";
const BASE_URL_YTB = "https://www.youtube.com/premium";
const BASE_URL_Param = "https://www.paramountplus.com/";
const BASE_URL_GPT = "https://chat.openai.com/";
const Region_URL_GPT = "https://chat.openai.com/cdn-cgi/trace";
const FILM_ID = 81280792;

const arrow = " ➟ ";
const UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.61 Safari/537.36";

const STATUS_COMING = 2;
const STATUS_AVAILABLE = 1;
const STATUS_NOT_AVAILABLE = 0;
const STATUS_TIMEOUT = -1;
const STATUS_ERROR = -2;

const opts = {
  policy: $environment.params
};

const opts1 = {
  policy: $environment.params,
  redirection: false
};

const result = {
  title: "    📺  流媒体服务查询",
  Netflix: "<b>Netflix: </b>不支持 🚫",
  Disney: "<b>Disneyᐩ: </b>不支持 🚫",
  ChatGPT: "<b>ChatGPT: </b>不支持 🚫",
  YouTube: "<b>YouTube Premium: </b>不支持 🚫",
  Paramount: "<b>Paramountᐩ: </b>不支持 🚫",
  Reddit: "<b>Reddit: </b>不支持 🚫"
};

const message = {
  action: "get_policy_state",
  content: $environment.params
};

const support_countryCodes = [
  "T1", "XX", "AL", "DZ", "AD", "AO", "AG", "AR", "AM", "AU", "AT", "AZ",
  "BS", "BD", "BB", "BE", "BZ", "BJ", "BT", "BA", "BW", "BR", "BG", "BF",
  "CV", "CA", "CL", "CO", "KM", "CR", "HR", "CY", "DK", "DJ", "DM", "DO",
  "EC", "SV", "EE", "FJ", "FI", "FR", "GA", "GM", "GE", "DE", "GH", "GR",
  "GD", "GT", "GN", "GW", "GY", "HT", "HN", "HU", "IS", "IN", "ID", "IQ",
  "IE", "IL", "IT", "JM", "JP", "JO", "KZ", "KE", "KI", "KW", "KG", "LV",
  "LB", "LS", "LR", "LI", "LT", "LU", "MG", "MW", "MY", "MV", "ML", "MT",
  "MH", "MR", "MU", "MX", "MC", "MN", "ME", "MA", "MZ", "MM", "NA", "NR",
  "NP", "NL", "NZ", "NI", "NE", "NG", "MK", "NO", "OM", "PK", "PW", "PA",
  "PG", "PE", "PH", "PL", "PT", "QA", "RO", "RW", "KN", "LC", "VC", "WS",
  "SM", "ST", "SN", "RS", "SC", "SL", "SG", "SK", "SI", "SB", "ZA", "ES",
  "LK", "SR", "SE", "CH", "TH", "TG", "TO", "TT", "TN", "TR", "TV", "UG",
  "AE", "US", "UY", "VU", "ZM", "BO", "BN", "CG", "CZ", "VA", "FM", "MD",
  "PS", "KR", "TW", "TZ", "TL", "GB"
];

function flag(region) {
  const code = String(region || "").toUpperCase();
  if (!/^[A-Z]{2}$/.test(code)) return "";
  return String.fromCodePoint(
    127397 + code.charCodeAt(0),
    127397 + code.charCodeAt(1)
  );
}

function unsupported(name) {
  result[name] = `<b>${displayName(name)}: </b>不支持 🚫`;
}

function displayName(name) {
  const names = {
    Netflix: "Netflix",
    Disney: "Disneyᐩ",
    ChatGPT: "ChatGPT",
    YouTube: "YouTube Premium",
    Paramount: "Paramountᐩ",
    Reddit: "Reddit"
  };
  return names[name];
}

;(async () => {
  const values = await Promise.all([
    testDisneyPlus(),
    testNf(FILM_ID),
    testChatGPT(),
    testYTB(),
    testParam(),
    testReddit()
  ]);

  const disney = values[0] || {};
  const region = disney.region;
  const status = disney.status;

  if (status === STATUS_COMING && region) {
    result.Disney =
      "<b>Disneyᐩ:</b> 即将登陆 ➟ ⟦" + flag(region) + "⟧ ⚠️";
  } else if (status === STATUS_AVAILABLE && region) {
    result.Disney =
      "<b>Disneyᐩ:</b> 支持 ➟ ⟦" + flag(region) + "⟧ 🎉";
  } else {
    unsupported("Disney");
  }

  let output = $environment.params;
  try {
    const policyState = await $configuration.sendMessage(message);
    if (policyState && policyState.ret) {
      const state = policyState.ret[message.content];
      output = state
        ? JSON.stringify(state)
            .replace(/\"|\[|\]/g, "")
            .replace(/\,/g, " ➟ ")
        : $environment.params;
    }
  } catch (error) {
    console.log("Policy State Error: " + error);
  }

  const content =
    "--------------------------------------</br>" +
    [
      result.Netflix,
      result.Disney,
      result.ChatGPT,
      result.YouTube,
      result.Paramount,
      result.Reddit
    ].join("</br></br>") +
    "</br>--------------------------------------</br>" +
    "<font color=#CD5C5C><b>节点</b> ➟ " +
    output +
    "</font>";

  const htmlMessage =
    '<p style="text-align: center; font-family: -apple-system; font-size: large; font-weight: thin">' +
    content +
    "</p>";

  $done({
    title: result.title,
    htmlMessage
  });
})().catch(error => {
  console.log("Media Check Error: " + error);
  const content =
    "--------------------------------------</br>" +
    [
      result.Netflix,
      result.Disney,
      result.ChatGPT,
      result.YouTube,
      result.Paramount,
      result.Reddit
    ].join("</br></br>") +
    "</br>--------------------------------------</br>" +
    "<font color=#CD5C5C><b>节点</b> ➟ " +
    $environment.params +
    "</font>";

  $done({
    title: result.title,
    htmlMessage:
      '<p style="text-align: center; font-family: -apple-system; font-size: large; font-weight: thin">' +
      content +
      "</p>"
  });
});

async function testDisneyPlus() {
  try {
    let { region } = await Promise.race([testHomePage(), timeout(7000)]);
    const { countryCode, inSupportedLocation, accessToken } =
      await Promise.race([getLocationInfo(), timeout(7000)]);

    region = countryCode ?? region;

    if (
      inSupportedLocation === false ||
      inSupportedLocation === "false"
    ) {
      return { region, status: STATUS_COMING };
    }

    return { region, status: STATUS_AVAILABLE, accessToken };
  } catch (error) {
    console.log("Disneyᐩ Error: " + error);
    if (error === "Not Available") {
      return { status: STATUS_NOT_AVAILABLE };
    }
    if (error === "Timeout") {
      return { status: STATUS_TIMEOUT };
    }
    return { status: STATUS_ERROR };
  }
}

function getLocationInfo() {
  return new Promise((resolve, reject) => {
    const option = {
      url: "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql",
      method: "POST",
      opts,
      headers: {
        "Accept-Language": "en",
        Authorization:
          "ZGlzbmV5JmJ3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84",
        "Content-Type": "application/json",
        "User-Agent": UA
      },
      body: JSON.stringify({
        query:
          "mutation registerDevice($input: RegisterDeviceInput!) { registerDevice(registerDevice: $input) { grant { grantType assertion } } }",
        variables: {
          input: {
            applicationRuntime: "chrome",
            attributes: {
              browserName: "chrome",
              browserVersion: "94.0.4606",
              manufacturer: "apple",
              model: null,
              operatingSystem: "macintosh",
              operatingSystemVersion: "10.15.7",
              osDeviceIds: []
            },
            deviceFamily: "browser",
            deviceLanguage: "en",
            deviceProfile: "macosx"
          }
        }
      })
    };

    $task.fetch(option).then(
      response => {
        if (response.statusCode !== 200) {
          reject("Not Available");
          return;
        }
        try {
          const sdk = JSON.parse(response.body)?.extensions?.sdk;
          const accessToken = sdk.token.accessToken;
          const inSupportedLocation = sdk.session.inSupportedLocation;
          const countryCode = sdk.session.location.countryCode;
          resolve({ inSupportedLocation, countryCode, accessToken });
        } catch (_) {
          reject("Error");
        }
      },
      () => reject("Error")
    );
  });
}

function testHomePage() {
  return new Promise((resolve, reject) => {
    const option = {
      url: "https://www.disneyplus.com/",
      opts,
      headers: {
        "Accept-Language": "en",
        "User-Agent": UA
      }
    };

    $task.fetch(option).then(
      response => {
        const data = response.body || "";
        if (
          response.statusCode !== 200 ||
          data.indexOf("not available in your region") !== -1
        ) {
          reject("Not Available");
          return;
        }
        const match = data.match(/Region: ([A-Za-z]{2})[\s\S]*?CNBL: ([12])/);
        resolve(
          match
            ? { region: match[1], cnbl: match[2] }
            : { region: "", cnbl: "" }
        );
      },
      () => reject("Error")
    );
  });
}

function timeout(delay = 5000) {
  return new Promise((_, reject) => {
    setTimeout(() => reject("Timeout"), delay);
  });
}

function testNf(filmId) {
  return new Promise(resolve => {
    const option = {
      url: BASE_URL + filmId,
      opts,
      timeout: 5200,
      headers: {
        "User-Agent":
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.61 Safari/537.36"
      }
    };

    $task.fetch(option).then(
      response => {
        console.log("nf:" + response.statusCode);
        if (response.statusCode === 404) {
          result.Netflix = "<b>Netflix: </b>支持自制剧集 ⚠️";
          resolve("Not Found");
          return;
        }

        if (response.statusCode === 403) {
          unsupported("Netflix");
          resolve("Not Available");
          return;
        }

        if (response.statusCode === 200) {
          try {
            const headers = response.headers || {};
            const url =
              headers["X-Originating-URL"] ||
              headers["x-originating-url"];
            let region = url.split("/")[3].split("-")[0];
            if (region === "title") region = "us";
            result.Netflix =
              "<b>Netflix: </b>完整支持" +
              arrow +
              "⟦" +
              flag(region) +
              "⟧ 🎉";
          } catch (_) {
            unsupported("Netflix");
          }
          resolve(result.Netflix);
          return;
        }

        unsupported("Netflix");
        resolve("Not Available");
      },
      () => {
        unsupported("Netflix");
        resolve("Not Available");
      }
    );
  });
}

function testYTB() {
  return new Promise(resolve => {
    const option = {
      url: BASE_URL_YTB,
      opts,
      timeout: 2800,
      headers: {
        "User-Agent":
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.61 Safari/537.36"
      }
    };

    $task.fetch(option).then(
      response => {
        const data = response.body || "";
        if (response.statusCode !== 200) {
          unsupported("YouTube");
        } else if (
          data.indexOf("Premium is not available in your country") !== -1
        ) {
          unsupported("YouTube");
        } else {
          let region = "";
          const match = /"GL":"(.*?)"/gm.exec(data);
          if (match && match.length === 2) {
            region = match[1];
          } else if (data.indexOf("www.google.cn") !== -1) {
            region = "CN";
          } else {
            region = "US";
          }
          result.YouTube =
            "<b>YouTube Premium: </b>支持 " +
            arrow +
            "⟦" +
            flag(region) +
            "⟧ 🎉";
        }
        resolve(result.YouTube);
      },
      () => {
        unsupported("YouTube");
        resolve(result.YouTube);
      }
    );
  });
}

function testParam() {
  return new Promise(resolve => {
    const option = {
      url: BASE_URL_Param,
      opts: opts1,
      timeout: 2800,
      headers: {
        "User-Agent":
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.61 Safari/537.36"
      }
    };

    $task.fetch(option).then(
      response => {
        if (response.statusCode === 200) {
          result.Paramount = "<b>Paramountᐩ: </b>支持 🎉";
        } else {
          unsupported("Paramount");
        }
        resolve(result.Paramount);
      },
      () => {
        unsupported("Paramount");
        resolve(result.Paramount);
      }
    );
  });
}

function testChatGPT() {
  return new Promise(resolve => {
    const option = {
      url: BASE_URL_GPT,
      opts: opts1,
      timeout: 2800
    };

    $task.fetch(option).then(
      response => {
        const responseText = JSON.stringify(response);
        if (responseText.indexOf("text/plain") !== -1) {
          unsupported("ChatGPT");
          resolve(result.ChatGPT);
          return;
        }

        const regionOption = {
          url: Region_URL_GPT,
          opts: opts1,
          timeout: 2800
        };

        $task.fetch(regionOption).then(
          regionResponse => {
            try {
              const region = regionResponse.body
                .split("loc=")[1]
                .split("\n")[0];
              if (support_countryCodes.indexOf(region) !== -1) {
                result.ChatGPT =
                  "<b>ChatGPT: </b>支持 " +
                  arrow +
                  "⟦" +
                  flag(region) +
                  "⟧ 🎉";
              } else {
                unsupported("ChatGPT");
              }
            } catch (_) {
              unsupported("ChatGPT");
            }
            resolve(result.ChatGPT);
          },
          () => {
            unsupported("ChatGPT");
            resolve(result.ChatGPT);
          }
        );
      },
      () => {
        unsupported("ChatGPT");
        resolve(result.ChatGPT);
      }
    );
  });
}

function testReddit() {
  return new Promise(resolve => {
    const option = {
      url: "https://www.reddit.com/",
      opts,
      timeout: 2800,
      headers: {
        "User-Agent": UA
      }
    };

    $task.fetch(option).then(
      response => {
        if (response.statusCode === 200) {
          result.Reddit = "<b>Reddit: </b>支持 🎉";
        } else {
          unsupported("Reddit");
        }
        resolve(result.Reddit);
      },
      () => {
        unsupported("Reddit");
        resolve(result.Reddit);
      }
    );
  });
}
